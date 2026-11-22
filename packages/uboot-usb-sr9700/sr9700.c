// SPDX-License-Identifier: GPL-2.0+
/*
 * CoreChip SR9700 — Ethernet USB 1.1 pour U-Boot.
 *
 * Portage du pilote noyau drivers/net/usb/sr9700.c (Liu Junliang, GPL-2.0+),
 * réduit à ce dont U-Boot a besoin : accès aux registres par requêtes vendor,
 * une trame émise à la fois, et la réception avec l'entête de trois octets.
 *
 * Contrainte matérielle, mesurée sur la puce du banc : USB pleine vitesse
 * (12 Mb/s) et **10 Mb/s half-duplex** seulement. Le débit utile plafonne vers
 * 1 Mo/s — de quoi amorcer une carte, pas de quoi juger un lien.
 */

#include <dm.h>
#include <errno.h>
#include <log.h>
#include <asm/cache.h>
#include <memalign.h>
#include <net.h>
#include <usb.h>
#include <asm/unaligned.h>
#include <linux/delay.h>
#include "usb_ether.h"

/* Chaque pilote USB-Ethernet d'U-Boot definit ses propres delais. */
#define USB_CTRL_SET_TIMEOUT	5000
#define USB_CTRL_GET_TIMEOUT	5000
#define USB_BULK_SEND_TIMEOUT	5000
/* Le noyau alloue 3072 octets de tampon de reception pour cette puce. */
#define RX_URB_SIZE		3072

/* Registres (cf. sr9700.h du noyau) */
#define SR_NCR			0x00
#define   NCR_RST		BIT(0)
#define SR_NSR			0x01
#define   NSR_LINKST		BIT(6)
#define SR_TCR			0x02
#define SR_TSR1			0x03
#define SR_RCR			0x05
#define   RCR_RXEN		BIT(0)
#define   RCR_ALL		BIT(3)
#define   RCR_DIS_CRC		BIT(4)
#define   RCR_DIS_LONG		BIT(5)
#define SR_RSR			0x06
#define   RSR_MF		BIT(6)	/* marque d'une trame valide */
#define SR_PAR			0x10	/* 0x10..0x15 : adresse MAC */
#define SR_PRR			0x1F
#define   PRR_PHY_RST		BIT(0)

/* Requêtes vendor : wValue = registre (lecture, écriture multiple) ou donnée */
#define SR_RD_REGS		0x00
#define SR_WR_MULTIPLE_REGS	0x01
#define SR_WR_SINGLE_REG	0x03
#define SR_REQ_RD_REG	(USB_DIR_IN | USB_TYPE_VENDOR | USB_RECIP_DEVICE)
#define SR_REQ_WR_REG	(USB_DIR_OUT | USB_TYPE_VENDOR | USB_RECIP_DEVICE)

#define SR_TX_OVERHEAD		2	/* longueur sur 2 octets */
#define SR_RX_OVERHEAD		7	/* 3 octets d'entête + 4 de CRC */
#define SR_LINK_POLL_MS		10
#define SR_LINK_TIMEOUT_MS	5000

struct sr9700_priv {
	struct ueth_data ueth;
	int tx_dbg;
};

static int sr9700_read(struct usb_device *udev, u8 reg, u16 len, void *data)
{
	int ret;

	ret = usb_control_msg(udev, usb_rcvctrlpipe(udev, 0), SR_RD_REGS,
			      SR_REQ_RD_REG, 0, reg, data, len,
			      USB_CTRL_GET_TIMEOUT);
	if (ret == len)
		return 0;

	return ret < 0 ? ret : -EINVAL;
}

static int sr9700_write(struct usb_device *udev, u8 reg, u16 len,
			const void *data)
{
	int ret;

	ret = usb_control_msg(udev, usb_sndctrlpipe(udev, 0),
			      SR_WR_MULTIPLE_REGS, SR_REQ_WR_REG, 0, reg,
			      (void *)data, len, USB_CTRL_SET_TIMEOUT);
	if (ret < 0)
		return ret;

	return ret == len ? 0 : -EINVAL;
}

static int sr9700_read_reg(struct usb_device *udev, u8 reg, u8 *value)
{
	return sr9700_read(udev, reg, 1, value);
}

static int sr9700_write_reg(struct usb_device *udev, u8 reg, u8 value)
{
	int ret;

	ret = usb_control_msg(udev, usb_sndctrlpipe(udev, 0),
			      SR_WR_SINGLE_REG, SR_REQ_WR_REG, value, reg,
			      NULL, 0, USB_CTRL_SET_TIMEOUT);

	return ret < 0 ? ret : 0;
}

static int sr9700_eth_start(struct udevice *dev)
{
	printf("sr9700: start appele\n");
	struct eth_pdata *pdata = dev_get_plat(dev);
	struct sr9700_priv *priv = dev_get_priv(dev);
	struct usb_device *udev = priv->ueth.pusb_dev;
	u8 mac[ETH_ALEN], nsr = 0;
	int i, ret;

	/* reset du contrôleur, 20 ms comme le noyau */
	sr9700_write_reg(udev, SR_NCR, NCR_RST);
	udelay(20);

	/*
	 * La MAC vient de l'EEPROM (ou d'une valeur par défaut du silicium, la
	 * puce recopie l'une ou l'autre dans PAR à la mise sous tension).
	 * U-Boot, lui, a déjà choisi une adresse — dérivée de la SID pour la
	 * famille. C'est elle qui doit sortir sur le fil, sinon le bail DHCP
	 * d'U-Boot et celui du noyau ne désignent pas la même unité.
	 */
	ret = sr9700_read(udev, SR_PAR, ETH_ALEN, mac);
	if (ret)
		return ret;

	if (is_valid_ethaddr(pdata->enetaddr)) {
		if (memcmp(pdata->enetaddr, mac, ETH_ALEN))
			sr9700_write(udev, SR_PAR, ETH_ALEN, pdata->enetaddr);
	} else if (is_valid_ethaddr(mac)) {
		memcpy(pdata->enetaddr, mac, ETH_ALEN);
	}

	/* reset de la PHY interne : 20 ms bas, 2 ms de stabilisation */
	sr9700_write_reg(udev, SR_PRR, PRR_PHY_RST);
	mdelay(20);
	sr9700_write_reg(udev, SR_PRR, 0);
	udelay(2 * 1000);

	/*
	 * Réception : activée, CRC et trames trop longues ignorés. `RCR_ALL`
	 * ouvre le filtre — U-Boot veut le broadcast (DHCP, ARP) et n'a que
	 * quelques trames à recevoir, la puce n'ayant de toute façon pas de
	 * filtre multicast.
	 */
	sr9700_write_reg(udev, SR_RCR,
			 RCR_RXEN | RCR_ALL | RCR_DIS_CRC | RCR_DIS_LONG);

	/* lien : NSR suffit, la puce ne sait faire que 10M half-duplex */
	for (i = 0; i < SR_LINK_TIMEOUT_MS / SR_LINK_POLL_MS; i++) {
		if (!sr9700_read_reg(udev, SR_NSR, &nsr) &&
		    (nsr & NSR_LINKST))
			break;
		mdelay(SR_LINK_POLL_MS);
	}

	if (nsr & NSR_LINKST)
		printf("sr9700: lien 10M half-duplex\n");
	else
		printf("sr9700: pas de lien (NSR=%02x)\n", nsr);

	return 0;
}

/*
 * L'endpoint d'interruption porte l'etat de la puce : b1 = NSR, b2 = TSR1,
 * b3 = TSR2, b4 = RSR, b5 = debordement RX, b6 = compteur RX, b7 = compteur
 * TX, b8 = registre general. Le pilote noyau y soumet un URB en permanence ;
 * sans lecture, les compteurs de la puce saturent et elle finit par bloquer
 * les transferts (mesure : premier envoi accepte, suivant en -EIO).
 */
static void sr9700_poll_int(struct sr9700_priv *priv)
{
	u8 st[8] = { 0 };
	int ret;

	if (!priv->ueth.ep_int)
		return;

	ret = usb_int_msg(priv->ueth.pusb_dev,
			  usb_rcvintpipe(priv->ueth.pusb_dev, priv->ueth.ep_int),
			  st, sizeof(st), priv->ueth.irqinterval, true);
	if (priv->tx_dbg < 6)
		printf("sr9700: int ret=%d nsr=%02x tsr1=%02x tsr2=%02x rsr=%02x\n",
		       ret, st[0], st[1], st[2], st[3]);
}

static int sr9700_eth_send(struct udevice *dev, void *packet, int length)
{
	struct sr9700_priv *priv = dev_get_priv(dev);
	struct usb_device *udev = priv->ueth.pusb_dev;
	ALLOC_CACHE_ALIGN_BUFFER(unsigned char, msg,
				 PKTSIZE + SR_TX_OVERHEAD);
	u16 len = length;
	int actual, ret;

	if (length > PKTSIZE || length <= 0)
		return -ENOSPC;

	/*
	 * La puce tronque une trame dont la longueur totale est un multiple
	 * de la taille de paquet USB : le noyau ajoute alors un octet, on fait
	 * de même (cf. sr9700_tx_fixup).
	 */
	if (((length + SR_TX_OVERHEAD) % 64) == 0)
		len++;

	msg[0] = len & 0xff;
	msg[1] = len >> 8;
	memcpy(msg + SR_TX_OVERHEAD, packet, length);

	ret = usb_bulk_msg(udev, usb_sndbulkpipe(udev, priv->ueth.ep_out),
			   msg, length + SR_TX_OVERHEAD, &actual,
			   USB_BULK_SEND_TIMEOUT);

	sr9700_poll_int(priv);

	/* Trace des premiers envois : la puce a-t-elle transmis ? */
	if (priv->tx_dbg < 4) {
		u8 nsr = 0, tsr1 = 0, tcr = 0;

		sr9700_read_reg(udev, SR_NSR, &nsr);
		sr9700_read_reg(udev, SR_TSR1, &tsr1);
		sr9700_read_reg(udev, SR_TCR, &tcr);
		printf("sr9700: tx len=%d ret=%d actual=%d NSR=%02x TSR1=%02x TCR=%02x\n",
		       length, ret, actual, nsr, tsr1, tcr);
		priv->tx_dbg++;
	}

	if (ret)
		return ret;

	return actual == length + SR_TX_OVERHEAD ? 0 : -EIO;
}

static int sr9700_eth_recv(struct udevice *dev, int flags, uchar **packetp)
{
	struct sr9700_priv *priv = dev_get_priv(dev);
	struct ueth_data *ueth = &priv->ueth;
	u8 *ptr;
	int len, pkt_len, ret;

	len = usb_ether_get_rx_bytes(ueth, &ptr);
	if (!len) {
		if (!(flags & ETH_RECV_CHECK_DEVICE))
			return -EAGAIN;

		sr9700_poll_int(priv);
		ret = usb_ether_receive(ueth, RX_URB_SIZE);
		if (ret) {
			/* un timeout n'est pas une faute : on repassera */
			sr9700_poll_int(priv);
			return -EAGAIN;
		}

		len = usb_ether_get_rx_bytes(ueth, &ptr);
		if (!len)
			return -EAGAIN;
	}

	/*
	 * Format : b1 = statut (RSR_MF pour une trame valide), b2/b3 =
	 * longueur incluant le CRC, puis les données et 4 octets de CRC. Un
	 * tampon peut porter plusieurs trames ; on n'en rend qu'une, la suite
	 * au prochain appel.
	 */
	if (len < SR_TX_OVERHEAD + 1 || ptr[0] != RSR_MF) {
		usb_ether_advance_rxbuf(ueth, len);
		return -EAGAIN;
	}

	pkt_len = ptr[1] | (ptr[2] << 8);
	if (pkt_len <= 4 || pkt_len + 3 > len) {
		usb_ether_advance_rxbuf(ueth, len);
		return -EAGAIN;
	}

	*packetp = ptr + 3;

	return pkt_len - 4;
}

static int sr9700_free_pkt(struct udevice *dev, uchar *packet, int length)
{
	struct sr9700_priv *priv = dev_get_priv(dev);

	usb_ether_advance_rxbuf(&priv->ueth, length + SR_RX_OVERHEAD);

	return 0;
}

static int sr9700_write_hwaddr(struct udevice *dev)
{
	struct eth_pdata *pdata = dev_get_plat(dev);
	struct sr9700_priv *priv = dev_get_priv(dev);

	return sr9700_write(priv->ueth.pusb_dev, SR_PAR, ETH_ALEN,
			    pdata->enetaddr);
}

static int sr9700_read_rom_hwaddr(struct udevice *dev)
{
	struct eth_pdata *pdata = dev_get_plat(dev);
	struct sr9700_priv *priv = dev_get_priv(dev);
	u8 mac[ETH_ALEN];
	int ret;

	ret = sr9700_read(priv->ueth.pusb_dev, SR_PAR, ETH_ALEN, mac);
	if (ret)
		return ret;
	if (!is_valid_ethaddr(mac))
		return -EINVAL;

	memcpy(pdata->enetaddr, mac, ETH_ALEN);

	return 0;
}

/*
 * Enregistrement aupres du cadre usb_ether, avec une difference : on choisit
 * l'interface. `usb_ether_register()` force l'interface 0, ce qui ne convient
 * qu'a la puce nue : la variante 0fe6:9702 expose un CD-ROM virtuel en
 * interface 0 et l'Ethernet en interface 1. On reproduit donc la decouverte
 * des points de terminaison, en gardant les memes exigences (bulk IN, bulk
 * OUT et interruption).
 */
static int sr9700_register(struct udevice *dev, struct ueth_data *ueth,
			   int ifnum, int rxsize)
{
	struct usb_device *udev = dev_get_parent_priv(dev);
	struct usb_interface *iface;
	struct usb_interface_descriptor *iface_desc;
	bool ep_in_found = false, ep_out_found = false;
	int i, ret;

	if (ifnum >= udev->config.no_of_if)
		return -ENODEV;

	iface = &udev->config.if_desc[ifnum];
	iface_desc = &iface->desc;

	ueth->ifnum = ifnum;
	ueth->subclass = iface_desc->bInterfaceSubClass;
	ueth->protocol = iface_desc->bInterfaceProtocol;
	ueth->ep_in = 0;
	ueth->ep_out = 0;
	ueth->ep_int = 0;

	for (i = 0; i < iface_desc->bNumEndpoints; i++) {
		int ep_addr = iface->ep_desc[i].bEndpointAddress;

		if ((iface->ep_desc[i].bmAttributes &
		     USB_ENDPOINT_XFERTYPE_MASK) == USB_ENDPOINT_XFER_BULK) {
			if ((ep_addr & USB_DIR_IN) && !ep_in_found) {
				ueth->ep_in = ep_addr & USB_ENDPOINT_NUMBER_MASK;
				ep_in_found = true;
			} else if (!(ep_addr & USB_DIR_IN) && !ep_out_found) {
				ueth->ep_out = ep_addr & USB_ENDPOINT_NUMBER_MASK;
				ep_out_found = true;
			}
		}

		if ((iface->ep_desc[i].bmAttributes &
		     USB_ENDPOINT_XFERTYPE_MASK) == USB_ENDPOINT_XFER_INT) {
			ueth->ep_int = iface->ep_desc[i].bEndpointAddress &
				       USB_ENDPOINT_NUMBER_MASK;
			ueth->irqinterval = iface->ep_desc[i].bInterval;
		}
	}

	if (!ueth->ep_in || !ueth->ep_out || !ueth->ep_int) {
		printf("sr9700: interface %d sans les trois points de terminaison\n",
		       ifnum);
		return -ENXIO;
	}

	ueth->rxsize = rxsize;
	ueth->rxbuf = memalign(ARCH_DMA_MINALIGN, rxsize);
	if (!ueth->rxbuf)
		return -ENOMEM;

	ret = usb_set_interface(udev, iface_desc->bInterfaceNumber, ifnum);
	if (ret)
		return ret;

	ueth->pusb_dev = udev;

	return 0;
}

static int sr9700_eth_probe(struct udevice *dev)
{
	struct sr9700_priv *priv = dev_get_priv(dev);
	struct usb_device *udev = dev_get_parent_priv(dev);
	int ret, i;

	/* Trace de mise au point : on veut savoir si le probe est appele. */
	printf("sr9700: probe %04x:%04x, %d interface(s)\n",
	       udev->descriptor.idVendor, udev->descriptor.idProduct,
	       udev->config.no_of_if);
	for (i = 0; i < udev->config.no_of_if; i++) {
		struct usb_interface *itf = &udev->config.if_desc[i];
		int j;

		printf("sr9700:   itf %d class %02x/%02x, %d ep",
		       i, itf->desc.bInterfaceClass, itf->desc.bInterfaceSubClass,
		       itf->desc.bNumEndpoints);
		for (j = 0; j < itf->desc.bNumEndpoints; j++)
			printf(" [%02x attr%02x max%03x]",
			       itf->ep_desc[j].bEndpointAddress,
			       itf->ep_desc[j].bmAttributes,
			       itf->ep_desc[j].wMaxPacketSize);
		printf("\n");
	}

	/*
	 * 0fe6:9702 = CD-ROM virtuel en interface 0, Ethernet en interface 1.
	 * Les deux references existent ; on essaie l'interface attendue, puis
	 * l'autre, pour ne pas dependre du numero de produit declare.
	 */
	if (udev->descriptor.idProduct == 0x9702)
		ret = sr9700_register(dev, &priv->ueth, 1, RX_URB_SIZE);
	else
		ret = sr9700_register(dev, &priv->ueth, 0, RX_URB_SIZE);

	if (ret) {
		ret = sr9700_register(dev, &priv->ueth,
				      udev->descriptor.idProduct == 0x9702 ? 0 : 1,
				      RX_URB_SIZE);
		if (ret)
			printf("sr9700: enregistrement impossible (%d)\n", ret);
	}

	if (!ret)
		printf("sr9700: ep_in=%d ep_out=%d ep_int=%d (attendu 81/02/83)\n",
		       priv->ueth.ep_in, priv->ueth.ep_out, priv->ueth.ep_int);

	return ret;
}

static void sr9700_eth_stop(struct udevice *dev)
{
}

static const struct eth_ops sr9700_eth_ops = {
	.start		= sr9700_eth_start,
	.send		= sr9700_eth_send,
	.recv		= sr9700_eth_recv,
	.free_pkt	= sr9700_free_pkt,
	.stop		= sr9700_eth_stop,
	.write_hwaddr	= sr9700_write_hwaddr,
	.read_rom_hwaddr = sr9700_read_rom_hwaddr,
};

U_BOOT_DRIVER(sr9700_eth) = {
	.name		= "sr9700_eth",
	.id		= UCLASS_ETH,
	.probe		= sr9700_eth_probe,
	.ops		= &sr9700_eth_ops,
	.priv_auto	= sizeof(struct sr9700_priv),
	.plat_auto	= sizeof(struct eth_pdata),
};

/*
 * 0x9700 est la puce nue ; 0x9702 est la même avec un CD-ROM virtuel en
 * interface 0, l'Ethernet étant alors l'interface 1 — non couvert ici.
 */
static const struct usb_device_id sr9700_eth_id_table[] = {
	{ USB_DEVICE(0x0fe6, 0x9700) },	/* puce nue */
	{ USB_DEVICE(0x0fe6, 0x9702) },	/* avec CD-ROM virtuel, Ethernet = interface 1 */
	{ }
};

U_BOOT_USB_DEVICE(sr9700_eth, sr9700_eth_id_table);
