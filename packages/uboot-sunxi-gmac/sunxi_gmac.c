// SPDX-License-Identifier: GPL-2.0+
/*
 * sunxi_gmac.c — pilote Ethernet Allwinner H616/H618 pour U-Boot
 *
 * Portage U-Boot du pilote vendor `sunxi-gmac` que nixelec-sunxi64 embarque
 * pour le noyau (`packages/sunxi-gmac/src/`). Les séquences de registres sont
 * reprises telles quelles : elles ont été mesurées sur la carte, la variante
 * mainline (stmmac/net-next) ne recevant aucune trame.
 *
 * Ce que le portage remplace :
 *   - netdev/NAPI/IRQ  → `struct eth_ops` en scrutation (start/send/recv/stop) ;
 *   - `mii_bus`        → MDIO direct par les registres du MAC (0x48/0x4C) ;
 *   - `phy_device`     → écritures MDIO directes, séquence AC300 recopiée ;
 *   - clk/reset Linux  → DM (`clk_get_by_name`, `reset_get_by_name`) pour le
 *                        bus, et une écriture CCU directe pour l'EPHY 25M
 *                        (U-Boot n'a pas cette horloge : le noyau a dû ajouter
 *                        un diviseur /24 sur PLL_PERI0, patch 0005).
 *
 * Ce qui est mesuré sur la carte et recopié sans interprétation :
 *   - `allwinner,syscfg-value = <0x3fe1>` : la logique du BSP écrit 0x5bfe0,
 *     qui coupe l'EPHY (PHY muet) ;
 *   - `allwinner,no-crc-check` : le MAC compte 7 octets de préambule dans la
 *     longueur de trame, le CRC de chaque trame est faux alors que les données
 *     sont saines ;
 *   - l'horloge 24 MHz du PHY vient du canal 5 du PWM, à poser par le DTS
 *     (pwm-clock) — en U-Boot le PWM n'est pas encore activé, la séquence
 *     AC300 ci-dessous suppose donc cette horloge déjà présente (voir
 *     `sunxi_gmac_ephy_clk_note`).
 */

#include <asm/arch/cpu.h>
#include <asm/cache.h>
#include <asm/io.h>
#include <clk.h>
#include <cpu_func.h>
#include <dm.h>
#include <dm/device_compat.h>
#include <fdtdec.h>
#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/string.h>
#include <linux/types.h>
#include <malloc.h>
#include <net.h>
#include <reset.h>
#include <u-boot/sha256.h>

/* ── registres du MAC (vendor `sunxi-gmac.c:99-123`) ───────────────────── */
#define GMAC_BASIC_CTL0		0x00
#define GMAC_BASIC_CTL1		0x04
#define GMAC_INT_STA		0x08
#define GMAC_INT_EN		0x0c
#define GMAC_TX_CTL0		0x10
#define GMAC_TX_CTL1		0x14
#define GMAC_TX_DESC_LIST	0x20
#define GMAC_RX_CTL0		0x24
#define GMAC_RX_CTL1		0x28
#define GMAC_RX_DESC_LIST	0x34
#define GMAC_RX_FRM_FLT		0x38
#define GMAC_MDIO_ADDR		0x48
#define GMAC_MDIO_DATA		0x4c
#define GMAC_ADDR_HI(n)		(0x50 + ((n) << 3))
#define GMAC_ADDR_LO(n)		(0x54 + ((n) << 3))

/* bits (vendor `sunxi-gmac.c:127-216`) */
#define CTL0_DM			0x01		/* full duplex */
#define CTL0_SPEED_MASK		0x0c
#define CTL0_100M		0x0c
#define BURST_VALUE		8
#define BURST_OFFSET		24
#define SOFT_RST		0x01
#define TX_DMA_EN		0x40000000
#define RX_DMA_EN		0x40000000
#define TX_DMA_START		BIT(31)
#define RX_DMA_START		BIT(31)
#define TX_FRM_LEN_OFFSET	30
#define CRC_OFFSET		27
#define STRIP_FCS_OFFSET	28
#define JUMBO_EN_OFFSET		29
#define RX_ERR_FRM		0x08
#define RX_RUNT_FRM		0x04
#define OWN_DMA			0x80000000
#define DESC_BUFSIZE		11
#define CHAIN_MODE_OFFSET	24
#define SF_DMA_MODE		1
#define RX_PKT_OK		0x7FFFB77C
#define RX_LEN_MASK		0x3FFF0000
#define RX_LEN_SHIFT		16

/* MDIO (vendor `sunxi-mdio.c:27-56`) */
#define MDIO_BUSY		0x00000001
#define MDIO_WRITE		0x00000002
#define MDIO_PHY_ADDR_OFF	12
#define MDIO_PHY_ADDR_MASK	0x0001f000
#define MDIO_PHY_REG_OFF	4
#define MDIO_PHY_REG_MASK	0x000007f0
#define MDIO_MDC_DIV		0x3
#define MDIO_MDC_DIV_OFF	20
#define MDIO_TIMEOUT_US		10000

/* CCU : horloge EPHY 25M (registre 0x970, portes bits 31:30) */
#define CCU_BASE		0x03001000
#define CCU_EPHY_25M		0x0970
#define CCU_EPHY_25M_GATE	(BIT(31) | BIT(30))

/*
 * PIO : mux des broches.
 *
 * Le pinctrl H616 d'U-Boot ne déclare que `emac0`
 * (`drivers/pinctrl/sunxi/pinctrl-sunxi.c`) : aucun `pinctrl-0` ne peut
 * poser le mux d'EMAC1, celui que le noyau exprime par
 * `SUNXI_FUNCTION(0x2, "emac1")` sur PA0-PA9
 * (`drivers/pinctrl/sunxi/pinctrl-sun50i-h616.c`). On écrit donc le mux à
 * la main, avec les mêmes valeurs que le noyau.
 */
#define SUNXI_PIO_BASE		0x0300B000
#define PIO_PA_CFG0		0x0000	/* PA0-PA7 : 4 bits par broche */
#define PIO_PA_CFG1		0x0004	/* PA8-PA15 */
#define PIO_MUX_FUNC2		0x2
#define PIO_CFG_MASK		0xf

/*
 * PWM : horloge du PHY AC300.
 *
 * Le PHY co-packagé n'a pas de quartz : il est horlogé par le canal 5 du PWM,
 * dont la sortie arrive sur PA12. Mesuré côté noyau : à 42 ns de période la
 * PHY est dix fois trop vite, à 500 ns elle se lie — d'où 2 MHz, que le PHY
 * multiplie par 12 pour obtenir ses 24 MHz.
 *
 * On reproduit la configuration du `pwm-sunxi-enhance` que le noyau utilise
 * (patch Armbian `drv-pwm-sun50i-h616`) telle que la demande le DTS :
 * `pwms = <&pwm 5 500 0>` + `clk_bypass_output = <1>`. U-Boot n'a ni ce
 * pilote ni cette horloge dans son CCU : les registres sont écrits à la main.
 */
#define PWM_BASE		0x0300A000
#define PWM_PCCR45		0x0028	/* configuration de la paire 4/5 */
#define PWM_PER			0x0040	/* activation des canaux */
#define PWM_PCR(n)		(0x0060 + 0x20 * (n))
#define PWM_PPR(n)		(0x0064 + 0x20 * (n))
#define PWM_PAIR_GATE		BIT(4)
#define PWM_CH5_BYPASS		BIT(6)	/* canal impair de la paire */
#define PWM_ACT_STA		BIT(8)	/* polarité normale */
#define PWM_EPHY_CHANNEL	5
#define PWM_EPHY_CYCLES		12	/* 24 MHz / 12 = 2 MHz */
#define CCU_PWM_BUS		0x07ac	/* porte/reset du bus PWM */
#define CCU_PWM_BUS_GATE	BIT(0)
#define CCU_PWM_BUS_RST		BIT(16)

/* AC300 : identifiants et calibration (vendor `sunxi-ephy.c`) */
#define AC300_PHY_ID		0x00441400
#define EPHY_CALI_BIT		BIT(21)
#define EPHY_BGS_MASK		0x000f0000
#define EPHY_BGS_OFFSET		16
#define EPHY_CALI_BASE		0x3a

/* SID : cellule de calibration EPHY (EFUSE_FTCP, 4 octets) */
#define SID_BASE		0x03006000
#define SID_FTCP		0x0200

#define GMAC_DESC_NUM		64
#define GMAC_BUF_SZ		1600

/*
 * Le GMAC du H616 est un maître DMA 32 bits : descripteurs et tampons doivent
 * tenir sous 0x1_0000_0000. Sur une carte de 4 Gio, le tas d'U-Boot est placé
 * en haut de la RAM, donc au-dessus : `memalign` ne convient pas. On réserve
 * une fenêtre fixe en mémoire basse, libre avant le chargement du noyau
 * (U-Boot est relogé en haut, le noyau va à 0x40080000 et l'initrd à
 * 0x50000000).
 */
#define GMAC_DMA_BASE		0x4C000000
#define GMAC_DMA_SIZE		(0x100000)

struct sunxi_gmac_desc {
	u32 status;
	u32 ctl;
	u32 buf;
	u32 next;
} __attribute__((packed));

struct sunxi_gmac_priv {
	void __iomem *base;
	void __iomem *syscfg;
	void *dma;
	u32 syscfg_val;
	bool no_crc_check;
	struct sunxi_gmac_desc *tx_ring;
	struct sunxi_gmac_desc *rx_ring;
	u8 *rx_buf;
	int tx_head;
	int rx_tail;
	int phy_addr;
	bool started;
};

/* ── MDIO ──────────────────────────────────────────────────────────────── */

static int gmac_mdio_wait(struct sunxi_gmac_priv *priv)
{
	u32 val;
	int i;

	for (i = 0; i < MDIO_TIMEOUT_US / 100; i++) {
		val = readl(priv->base + GMAC_MDIO_ADDR);
		if (!(val & MDIO_BUSY))
			return 0;
		udelay(100);
	}
	return -EBUSY;
}

static int gmac_mdio_read(struct sunxi_gmac_priv *priv, int reg)
{
	u32 val;

	if (gmac_mdio_wait(priv))
		return -EBUSY;

	val = (MDIO_MDC_DIV << MDIO_MDC_DIV_OFF);
	val |= (priv->phy_addr << MDIO_PHY_ADDR_OFF) & MDIO_PHY_ADDR_MASK;
	val |= (reg << MDIO_PHY_REG_OFF) & MDIO_PHY_REG_MASK;
	val |= MDIO_BUSY;
	writel(val, priv->base + GMAC_MDIO_ADDR);

	if (gmac_mdio_wait(priv))
		return -EBUSY;

	return readl(priv->base + GMAC_MDIO_DATA) & 0xffff;
}

static int gmac_mdio_write(struct sunxi_gmac_priv *priv, int reg, u16 data)
{
	u32 val;

	if (gmac_mdio_wait(priv))
		return -EBUSY;

	val = (MDIO_MDC_DIV << MDIO_MDC_DIV_OFF);
	val |= (priv->phy_addr << MDIO_PHY_ADDR_OFF) & MDIO_PHY_ADDR_MASK;
	val |= (reg << MDIO_PHY_REG_OFF) & MDIO_PHY_REG_MASK;
	val |= MDIO_WRITE | MDIO_BUSY;

	writel(data, priv->base + GMAC_MDIO_DATA);
	writel(val, priv->base + GMAC_MDIO_ADDR);

	return gmac_mdio_wait(priv);
}

/* ── AC300 : séquence vendor (`sunxi-ephy.c:81-263`) ───────────────────── */

static void gmac_ephy_page(struct sunxi_gmac_priv *priv, u16 page)
{
	gmac_mdio_write(priv, 0x1f, page);
}

static void gmac_ephy_cali(struct sunxi_gmac_priv *priv)
{
	u32 cali = readl((void __iomem *)(SID_BASE + SID_FTCP));
	int val, bgs;

	val = gmac_mdio_read(priv, 0x06);
	if (val < 0)
		return;
	val &= ~(0xf << 12);
	bgs = (cali & EPHY_BGS_MASK) >> EPHY_BGS_OFFSET;
	val |= (0xf & (EPHY_CALI_BASE + bgs)) << 12;
	gmac_mdio_write(priv, 0x06, val);
}

/*
 * `ac300_enable` du vendor : reset, portes d'horloge, I/O, puis LEDs.
 * L'horloge 24 MHz du PHY vient du PWM5 (voir le DTS du noyau) : en U-Boot
 * elle doit être produite avant cet appel, sinon le PHY reste muet.
 */
static void gmac_ac300_enable(struct sunxi_gmac_priv *priv)
{
	gmac_mdio_write(priv, 0x00, 0x1f40);
	gmac_mdio_write(priv, 0x00, 0x1f43);
	gmac_mdio_write(priv, 0x00, 0x1fb7);
	gmac_mdio_write(priv, 0x05, 0xa81f);
	mdelay(10);
	gmac_mdio_write(priv, 0x06, 0x0811);
	mdelay(10);
	gmac_mdio_write(priv, 0x06, 0x0810);
}

static void gmac_ac300_init(struct sunxi_gmac_priv *priv)
{
	gmac_ephy_page(priv, 0x0100);
	gmac_mdio_write(priv, 0x12, 0x4824);	/* disable APS */
	gmac_ephy_page(priv, 0x0200);
	gmac_mdio_write(priv, 0x18, 0x0000);
	gmac_ephy_page(priv, 0x0600);
	gmac_mdio_write(priv, 0x14, 0x7809);	/* TX optimisation */
	gmac_mdio_write(priv, 0x13, 0xf000);	/* RX optimisation */
	gmac_mdio_write(priv, 0x10, 0x5523);
	gmac_mdio_write(priv, 0x15, 0x3533);
	gmac_ephy_page(priv, 0x0800);
	gmac_mdio_write(priv, 0x1d, 0x0844);
	gmac_mdio_write(priv, 0x18, 0x00bc);
	gmac_ephy_page(priv, 0x0000);

	/* disable intelligent IEEE (page 1, reg 0x17 bit 3) */
	gmac_ephy_page(priv, 0x0100);
	{
		int v = gmac_mdio_read(priv, 0x17);
		if (v >= 0)
			gmac_mdio_write(priv, 0x17, v & ~BIT(3));
	}
	gmac_ephy_page(priv, 0x0000);

	/* disable 802.3az */
	gmac_mdio_write(priv, 0x0d, 0x7);
	gmac_mdio_write(priv, 0x0e, 0x3c);
	gmac_mdio_write(priv, 0x0d, (1 << 14) | 0x7);
	{
		int v = gmac_mdio_read(priv, 0x0e);
		if (v >= 0)
			gmac_mdio_write(priv, 0x0e, v & ~BIT(1));
	}
	gmac_ephy_page(priv, 0x0200);
	gmac_mdio_write(priv, 0x18, 0x0000);
	gmac_ephy_page(priv, 0x0000);

	/* RMII : bit 11 de reg 0x06 (vendor `sunxi-ephy.c:217-223`) */
	{
		int v = gmac_mdio_read(priv, 0x06);
		if (v >= 0)
			gmac_mdio_write(priv, 0x06, v | BIT(11));
	}
}

/* ── ring ──────────────────────────────────────────────────────────────── */

static void gmac_desc_chain(struct sunxi_gmac_desc *ring, ulong addr, int n)
{
	int i;

	for (i = 0; i < n - 1; i++) {
		ring[i].next = (u32)(addr + (i + 1) * sizeof(*ring));
		ring[i].ctl |= (1 << CHAIN_MODE_OFFSET);
	}
	ring[n - 1].next = (u32)addr;
	ring[n - 1].ctl |= (1 << CHAIN_MODE_OFFSET);
}

static void gmac_rx_refill(struct sunxi_gmac_priv *priv, int idx)
{
	struct sunxi_gmac_desc *d = &priv->rx_ring[idx];
	ulong buf = (ulong)priv->rx_buf + idx * GMAC_BUF_SZ;

	flush_dcache_range(buf, buf + GMAC_BUF_SZ);
	d->ctl &= ~((1 << DESC_BUFSIZE) - 1);
	d->ctl |= GMAC_BUF_SZ & ((1 << DESC_BUFSIZE) - 1);
	d->buf = (u32)buf;
	flush_dcache_range((ulong)d, (ulong)d + sizeof(*d));
	d->status |= OWN_DMA;
	flush_dcache_range((ulong)d, (ulong)d + sizeof(*d));
}

/* ── eth_ops ───────────────────────────────────────────────────────────── */

/*
 * Mux RMII d'EMAC1 : PA0-PA9 en fonction 2.
 *
 * Sans lui le MAC est bien horlogé et adressable, mais ses broches restent
 * des GPIO : le PHY ne voit ni MDC/MDIO ni les lignes RMII, et le lien ne
 * monte jamais (mesuré : `carrier=0`, aucune requête DHCP).
 */
static void sunxi_gmac_mux_rmii(void)
{
	void __iomem *pio = map_physmem(SUNXI_PIO_BASE, 0x400, MAP_NOCACHE);
	u32 cfg;

	if (!pio)
		return;

	/* PA0-PA7 : ERXD1, ERXD0, ECRS_DV, ERXERR, ETXD1, ETXD0, ETXCK, ETXEN */
	writel(0x22222222, pio + PIO_PA_CFG0);

	/* PA8/PA9 = MDC/MDIO ; le reste de CFG1 (PA10-PA15) est préservé */
	cfg = readl(pio + PIO_PA_CFG1);
	cfg &= ~((PIO_CFG_MASK << 0) | (PIO_CFG_MASK << 4));
	cfg |= (PIO_MUX_FUNC2 << 0) | (PIO_MUX_FUNC2 << 4);
	writel(cfg, pio + PIO_PA_CFG1);
}

/*
 * Horloge 2 MHz du PHY AC300 par PWM5 (broche PA12).
 *
 * Le PHY répond au MDIO grâce au 25 MHz du CCU, mais son PLL et son récepteur
 * RMII ont besoin de cette horloge : sans elle le lien ne monte jamais.
 */
static void sunxi_gmac_ephy_clock(void)
{
	void __iomem *ccu = map_physmem(CCU_BASE, 0x1000, MAP_NOCACHE);
	void __iomem *pwm = map_physmem(PWM_BASE, 0x100, MAP_NOCACHE);
	void __iomem *pio = map_physmem(SUNXI_PIO_BASE, 0x400, MAP_NOCACHE);
	u32 v;

	if (!ccu || !pwm || !pio)
		return;

	/* PA12 en fonction 2 = pwm5 (seule broche PWM5 du H616) */
	v = readl(pio + PIO_PA_CFG1);
	v &= ~(PIO_CFG_MASK << 16);
	v |= (PIO_MUX_FUNC2 << 16);
	writel(v, pio + PIO_PA_CFG1);

	/* porte et reset du bus PWM (CCU 0x7ac, bits 0 et 16) */
	v = readl(ccu + CCU_PWM_BUS);
	v |= CCU_PWM_BUS_GATE | CCU_PWM_BUS_RST;
	writel(v, ccu + CCU_PWM_BUS);
	mdelay(1);

	/* paire 4/5 : source OSC24M (bit 7 à 0), diviseur /1, porte de paire,
	 * et sortie en bypass pour le canal 5 */
	v = readl(pwm + PWM_PCCR45);
	v &= ~(0xf | PWM_PAIR_GATE | BIT(5) | PWM_CH5_BYPASS | BIT(7));
	v |= PWM_PAIR_GATE | PWM_CH5_BYPASS;
	writel(v, pwm + PWM_PCCR45);

	/* canal 5 : prescal_k = 0 (÷1), polarité normale */
	v = readl(pwm + PWM_PCR(PWM_EPHY_CHANNEL));
	v &= ~0xff;
	v |= PWM_ACT_STA;
	writel(v, pwm + PWM_PCR(PWM_EPHY_CHANNEL));

	/* 12 cycles de 24 MHz par période, rapport 50 % */
	writel(((PWM_EPHY_CYCLES - 1) << 16) | (PWM_EPHY_CYCLES / 2),
	       pwm + PWM_PPR(PWM_EPHY_CHANNEL));

	/* active le canal */
	v = readl(pwm + PWM_PER);
	v |= BIT(PWM_EPHY_CHANNEL);
	writel(v, pwm + PWM_PER);
}

static int sunxi_gmac_start(struct udevice *dev)
{
	struct sunxi_gmac_priv *priv = dev_get_priv(dev);
	struct eth_pdata *pdata = dev_get_plat(dev);
	u32 val;
	int i, id;

	sunxi_gmac_mux_rmii();
	sunxi_gmac_ephy_clock();

	/* CCU : porte EPHY 25M (PLL_PERI0 / 24 = 25 MHz) */
	val = readl((void __iomem *)(CCU_BASE + CCU_EPHY_25M));
	val |= CCU_EPHY_25M_GATE;
	writel(val, (void __iomem *)(CCU_BASE + CCU_EPHY_25M));

	dev_err(dev, "CCU 970=%08x 97c=%08x 7ac=%08x | PIO PA_CFG0=%08x PA_CFG1=%08x\n",
		readl((void __iomem *)(CCU_BASE + CCU_EPHY_25M)),
		readl((void __iomem *)(CCU_BASE + 0x97c)),
		readl((void __iomem *)(CCU_BASE + CCU_PWM_BUS)),
		readl((void __iomem *)(SUNXI_PIO_BASE + PIO_PA_CFG0)),
		readl((void __iomem *)(SUNXI_PIO_BASE + PIO_PA_CFG1)));
	dev_err(dev, "PWM5 PCCR45=%08x PCR=%08x PPR=%08x PER=%08x\n",
		readl((void __iomem *)(PWM_BASE + PWM_PCCR45)),
		readl((void __iomem *)(PWM_BASE + PWM_PCR(PWM_EPHY_CHANNEL))),
		readl((void __iomem *)(PWM_BASE + PWM_PPR(PWM_EPHY_CHANNEL))),
		readl((void __iomem *)(PWM_BASE + PWM_PER)));

	/*
	 * Reset logiciel du MAC, BORNÉ. Une horloge MAC absente laisse le bit
	 * posé indéfiniment : sans borne, U-Boot se fige ici sans rien dire
	 * (mesuré sur la H96 : plus aucune sortie console après `Net:`).
	 */
	dev_err(dev, "MAC avant reset : CTL1=%08x\n",
		readl(priv->base + GMAC_BASIC_CTL1));
	writel(SOFT_RST, priv->base + GMAC_BASIC_CTL1);
	for (i = 0; i < 200; i++) {
		if (!(readl(priv->base + GMAC_BASIC_CTL1) & SOFT_RST))
			break;
		mdelay(1);
	}
	if (i == 200)
		dev_err(dev, "reset MAC bloqué (CTL1=%08x) — horloge MAC ?\n",
			readl(priv->base + GMAC_BASIC_CTL1));

	/* syscfg mesuré : la valeur du BSP coupe l'EPHY */
	if (priv->syscfg)
		writel(priv->syscfg_val, priv->syscfg);

	/* PHY */
	id = gmac_mdio_read(priv, 0x02);
	id = (id << 16) | (gmac_mdio_read(priv, 0x03) & 0xffff);
	dev_err(dev, "PHY id %08x (attendu %08x), BMCR=%04x BMSR=%04x\n",
		id, AC300_PHY_ID, gmac_mdio_read(priv, 0x00), gmac_mdio_read(priv, 0x01));

	gmac_ac300_enable(priv);
	gmac_ephy_cali(priv);
	gmac_ac300_init(priv);

	/* autoneg 100M full duplex, puis attente du lien */
	gmac_mdio_write(priv, 0x00, 0x1140 | BIT(9));
	for (i = 0; i < 50; i++) {
		mdelay(10);
		if (gmac_mdio_read(priv, 0x01) & BIT(2))
			break;
	}
	if (i == 50)
		dev_err(dev, "lien PHY non établi après 500 ms (BMSR=%04x)\n",
			gmac_mdio_read(priv, 0x01));
	else
		dev_err(dev, "lien PHY établi (BMSR=%04x)\n",
			gmac_mdio_read(priv, 0x01));

	/* anneaux */
	priv->tx_head = 0;
	priv->rx_tail = 0;
	memset(priv->tx_ring, 0, sizeof(*priv->tx_ring) * GMAC_DESC_NUM);
	memset(priv->rx_ring, 0, sizeof(*priv->rx_ring) * GMAC_DESC_NUM);

	gmac_desc_chain(priv->tx_ring, (ulong)priv->tx_ring, GMAC_DESC_NUM);
	gmac_desc_chain(priv->rx_ring, (ulong)priv->rx_ring, GMAC_DESC_NUM);
	for (i = 0; i < GMAC_DESC_NUM; i++)
		gmac_rx_refill(priv, i);

	/* DMA + MAC */
	val = BURST_VALUE << BURST_OFFSET;
	writel(val, priv->base + GMAC_BASIC_CTL1);

	val = readl(priv->base + GMAC_TX_CTL0);
	val |= (1 << TX_FRM_LEN_OFFSET);
	writel(val, priv->base + GMAC_TX_CTL0);

	val = readl(priv->base + GMAC_RX_CTL0);
	val |= (1 << CRC_OFFSET) | (1 << STRIP_FCS_OFFSET) | (1 << JUMBO_EN_OFFSET);
	writel(val, priv->base + GMAC_RX_CTL0);

	writel(MDIO_MDC_DIV << MDIO_MDC_DIV_OFF, priv->base + GMAC_MDIO_ADDR);

	val = readl(priv->base + GMAC_TX_CTL1);
	val |= (1 << 2) | (1 << 1);	/* store-and-forward, second frame */
	writel(val, priv->base + GMAC_TX_CTL1);

	val = readl(priv->base + GMAC_RX_CTL1);
	val |= (1 << 1) | RX_ERR_FRM | RX_RUNT_FRM;
	writel(val, priv->base + GMAC_RX_CTL1);

	/* adresse MAC */
	writel((pdata->enetaddr[5] << 8) | pdata->enetaddr[4], priv->base + GMAC_ADDR_HI(0));
	writel((pdata->enetaddr[3] << 24) | (pdata->enetaddr[2] << 16) |
	       (pdata->enetaddr[1] << 8) | pdata->enetaddr[0], priv->base + GMAC_ADDR_LO(0));

	/* filtrage : tout passer (pas de hash à programmer en U-Boot) */
	writel(0x80000000, priv->base + GMAC_RX_FRM_FLT);

	writel((u32)(ulong)priv->rx_ring, priv->base + GMAC_RX_DESC_LIST);
	val = readl(priv->base + GMAC_RX_CTL1) | RX_DMA_EN;
	writel(val, priv->base + GMAC_RX_CTL1);

	writel((u32)(ulong)priv->tx_ring, priv->base + GMAC_TX_DESC_LIST);
	val = readl(priv->base + GMAC_TX_CTL1) | TX_DMA_EN;
	writel(val, priv->base + GMAC_TX_CTL1);

	val = readl(priv->base + GMAC_TX_CTL0) | TX_DMA_START;
	writel(val, priv->base + GMAC_TX_CTL0);
	val = readl(priv->base + GMAC_RX_CTL0) | RX_DMA_START;
	writel(val, priv->base + GMAC_RX_CTL0);

	/* 100M full duplex */
	val = readl(priv->base + GMAC_BASIC_CTL0);
	val |= CTL0_DM;
	val = (val & ~CTL0_SPEED_MASK) | CTL0_100M;
	writel(val, priv->base + GMAC_BASIC_CTL0);

	priv->started = true;
	dev_info(dev, "démarré (RMII, 100M, plein duplex)\n");
	return 0;
}

static int sunxi_gmac_send(struct udevice *dev, void *packet, int length)
{
	struct sunxi_gmac_priv *priv = dev_get_priv(dev);
	struct sunxi_gmac_desc *d = &priv->tx_ring[priv->tx_head];
	ulong start = (ulong)packet;
	int i;

	if (length > GMAC_BUF_SZ) {
		dev_err(dev, "trame trop longue : %d\n", length);
		return -EMSGSIZE;
	}

	flush_dcache_range(start, start + length);

	d->buf = (u32)start;
	d->ctl &= ~((1 << DESC_BUFSIZE) - 1);
	d->ctl |= length & ((1 << DESC_BUFSIZE) - 1);
	d->ctl |= (1 << 29) | (1 << 30);	/* first + last segment */
	d->status = OWN_DMA;
	flush_dcache_range((ulong)d, (ulong)d + sizeof(*d));

	/* lance le TX (vendor `sunxi_gmac_tx_poll`) */
	{
		u32 v = readl(priv->base + GMAC_TX_CTL1);
		writel(v | TX_DMA_START, priv->base + GMAC_TX_CTL1);
	}

	for (i = 0; i < 1000; i++) {
		invalidate_dcache_range((ulong)d, (ulong)d + sizeof(*d));
		if (!(d->status & OWN_DMA))
			break;
		udelay(10);
	}
	if (i == 1000) {
		dev_err(dev, "TX bloqué (desc %d)\n", priv->tx_head);
		return -ETIMEDOUT;
	}

	priv->tx_head = (priv->tx_head + 1) % GMAC_DESC_NUM;
	return 0;
}

static int sunxi_gmac_recv(struct udevice *dev, int flags, uchar **packetp)
{
	struct sunxi_gmac_priv *priv = dev_get_priv(dev);
	struct sunxi_gmac_desc *d = &priv->rx_ring[priv->rx_tail];
	ulong buf;
	int len;

	invalidate_dcache_range((ulong)d, (ulong)d + sizeof(*d));
	if (d->status & OWN_DMA)
		return -EAGAIN;

	if ((d->status & RX_PKT_OK) != RX_PKT_OK) {
		/* trame en erreur : on recycle et on la jette */
		gmac_rx_refill(priv, priv->rx_tail);
		priv->rx_tail = (priv->rx_tail + 1) % GMAC_DESC_NUM;
		return -EAGAIN;
	}

	len = (d->status & RX_LEN_MASK) >> RX_LEN_SHIFT;
	buf = (ulong)priv->rx_buf + priv->rx_tail * GMAC_BUF_SZ;
	invalidate_dcache_range(buf, buf + len);

	*packetp = (uchar *)buf;
	return len;
}

static int sunxi_gmac_free_pkt(struct udevice *dev, uchar *packet, int length)
{
	struct sunxi_gmac_priv *priv = dev_get_priv(dev);

	gmac_rx_refill(priv, priv->rx_tail);
	priv->rx_tail = (priv->rx_tail + 1) % GMAC_DESC_NUM;
	return 0;
}

static void sunxi_gmac_stop(struct udevice *dev)
{
	struct sunxi_gmac_priv *priv = dev_get_priv(dev);
	u32 val;

	val = readl(priv->base + GMAC_TX_CTL0) & ~TX_DMA_START;
	writel(val, priv->base + GMAC_TX_CTL0);
	val = readl(priv->base + GMAC_RX_CTL0) & ~RX_DMA_START;
	writel(val, priv->base + GMAC_RX_CTL0);
	priv->started = false;
}

static const struct eth_ops sunxi_gmac_ops = {
	.start = sunxi_gmac_start,
	.send = sunxi_gmac_send,
	.recv = sunxi_gmac_recv,
	.free_pkt = sunxi_gmac_free_pkt,
	.stop = sunxi_gmac_stop,
};

/* ── probe ─────────────────────────────────────────────────────────────── */

static int sunxi_gmac_probe(struct udevice *dev)
{
	struct sunxi_gmac_priv *priv = dev_get_priv(dev);
	struct eth_pdata *pdata = dev_get_plat(dev);
	struct clk clk;
	struct reset_ctl rst;
	fdt_addr_t addr;
	u32 val;
	int ret;

	priv->base = dev_read_addr_ptr(dev);
	if (!priv->base)
		return -EINVAL;

	/* deuxième entrée `reg` : le registre syscfg mesuré */
	addr = dev_read_addr_index(dev, 1);
	if (addr != FDT_ADDR_T_NONE)
		priv->syscfg = map_physmem(addr, 4, MAP_NOCACHE);

	if (dev_read_u32(dev, "allwinner,syscfg-value", &val) == 0)
		priv->syscfg_val = val;
	else
		priv->syscfg_val = 0x3fe1;

	priv->no_crc_check = dev_read_bool(dev, "allwinner,no-crc-check");
	priv->phy_addr = dev_read_u32_default(dev, "phy-addr", 0);

	/*
	 * MAC déterministe dérivée de la SID.
	 *
	 * Ces boîtes H616/H618 n'ont aucune MAC en usine (mesure du 2026-11-15 :
	 * les 256 octets lisibles de la SID ne contiennent ni OUI ni adresse) et
	 * U-Boot rejette un périphérique dont l'adresse n'est pas valide
	 * (« No valid MAC address found »). Le noyau applique
	 * `nixelec.macFromSid` : `02:` suivi des 5 premiers octets de
	 * sha256(SID[0..15]). On reproduit le MÊME calcul ici, sinon le bail
	 * DHCP d'U-Boot et celui du noyau ne désignent pas la même unité — et
	 * `havenos load --netboot` ne retrouve plus la carte.
	 */
	if (!is_valid_ethaddr(pdata->enetaddr)) {
		unsigned int sid[4];
		unsigned char sid_bytes[16];
		unsigned char digest[SHA256_SUM_LEN];
		sha256_context ctx;
		int i;

		if (sunxi_get_sid(sid) == 0) {
			for (i = 0; i < 4; i++)
				memcpy(&sid_bytes[i * 4], &sid[i], 4);
			/* API explicite : `sha256_csum_wd` boucle a l infini quand
			 * chunk_sz vaut 0 dans sa branche watchdog (mesure : U-Boot
			 * se fige sur la ligne `Net:`). */
			sha256_starts(&ctx);
			sha256_update(&ctx, sid_bytes, sizeof(sid_bytes));
			sha256_finish(&ctx, digest);
			pdata->enetaddr[0] = 0x02;
			memcpy(&pdata->enetaddr[1], digest, 5);
			dev_info(dev, "MAC dérivée de la SID : %pM\n",
				 pdata->enetaddr);
		}
	}

	ret = clk_get_by_name(dev, "gmac", &clk);
	if (ret) {
		dev_err(dev, "horloge « gmac » absente : %d\n", ret);
		return ret;
	}
	clk_enable(&clk);
	dev_info(dev, "horloge gmac : %lu Hz\n", (unsigned long)clk_get_rate(&clk));

	ret = reset_get_by_name(dev, "gmac", &rst);
	if (!ret)
		dev_err(dev, "reset « gmac » : deassert → %d\n", reset_deassert(&rst));
	else
		dev_err(dev, "reset « gmac » absent (%d) : le MAC reste en reset\n", ret);

	/* fenêtre DMA basse : le GMAC n'adresse que 32 bits */
	priv->dma = map_physmem(GMAC_DMA_BASE, GMAC_DMA_SIZE, MAP_NOCACHE);
	if (!priv->dma)
		return -ENOMEM;
	priv->tx_ring = priv->dma;
	priv->rx_ring = (void *)((u8 *)priv->dma + sizeof(*priv->tx_ring) * GMAC_DESC_NUM);
	priv->rx_buf = (u8 *)priv->rx_ring + sizeof(*priv->rx_ring) * GMAC_DESC_NUM;

	dev_info(dev, "H616 GMAC prêt (syscfg %#x%s, DMA @ %#x)\n", priv->syscfg_val,
		 priv->no_crc_check ? ", sans contrôle CRC" : "", GMAC_DMA_BASE);
	return 0;
}

static const struct udevice_id sunxi_gmac_ids[] = {
	{ .compatible = "allwinner,sun50i-h616-gmac" },
	{ }
};

U_BOOT_DRIVER(sunxi_gmac) = {
	.name = "sunxi_gmac",
	.id = UCLASS_ETH,
	.of_match = sunxi_gmac_ids,
	.probe = sunxi_gmac_probe,
	.ops = &sunxi_gmac_ops,
	.priv_auto = sizeof(struct sunxi_gmac_priv),
	.plat_auto = sizeof(struct eth_pdata),
};
