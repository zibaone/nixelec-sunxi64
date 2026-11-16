// SPDX-License-Identifier: MIT
//
// fd6xx — afficheur de facade 7 segments des boites H616/H618 (FD650/FD655).
//
// Ces dalles ne sont PAS sur un bus I2C du SoC : deux GPIO bit-banges
// (CLK/DAT), un protocole TWI maison. Et la puce **n'ACK pas** — mesure sur
// les deux cartes — donc `i2c-gpio` + un pilote I2C du noyau ne peuvent pas
// la piloter : i2c-gpio rend `-ENXIO` des le premier octet et le probe
// echoue. D'ou cet outil en espace utilisateur, qui parle le protocole
// directement par l'API gpio-v2.
//
// Protocole mesure (H96 Max H618, puce FD655) :
//   - START, octet de commande, 8 bits MSB d'abord, puis un **9e top
//     d'horloge** (la puce ne tire pas DAT : le 9e top est obligatoire quand
//     meme, sans lui des octets sont perdus — mesure), STOP ;
//   - commande 0x48 = controle, donnee = (niveau de luminosite + 1) << 4 | 0x01 ;
//   - adresses de donnees 0x68, 0x6A, 0x6C, 0x6E, 0x70 ; l'adresse 0x68 est
//     le chiffre **le plus a droite** (mesure sur la H96) ;
//   - un octet de donnee = DP G F E D C B A (bit 7 = point, bit 0 = segment A).
//
// Les lignes sont demandees en sortie **open-drain avec pull-up interne au
// SoC** : l'etat haut n'est jamais pousse, ce qui est le cablage reel (DAT
// est open-drain des deux cotes). Sans le pull-up explicite, une ligne
// relachee flotte et les trames sont perdues.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define MAX_GRIDS 5
#define CMD_CTRL 0x48
#define ADDR_BASE 0x68

static int gfd, reqfd;
static long dly_ns = 5000; /* demi-periode : 5 us, ~100 kHz */

static void die(const char *what)
{
	fprintf(stderr, "fd6xx: %s: %s\n", what, strerror(errno));
	exit(1);
}

/* bits des valeurs = position dans la requete (0 = clk, 1 = dat) */
static void set2(int clk, int dat)
{
	struct gpio_v2_line_values lv;

	memset(&lv, 0, sizeof(lv));
	lv.mask = 0x3;
	lv.bits = (clk ? 0x1 : 0) | (dat ? 0x2 : 0);
	if (ioctl(reqfd, GPIO_V2_LINE_SET_VALUES_IOCTL, &lv) < 0)
		die("set_values");
}

static void nsleep(long ns)
{
	struct timespec ts;

	ts.tv_sec = ns / 1000000000L;
	ts.tv_nsec = ns % 1000000000L;
	nanosleep(&ts, NULL);
}

static void bb_start(void)
{
	set2(1, 1);
	nsleep(dly_ns);
	set2(1, 0);
	nsleep(dly_ns);
	set2(0, 0);
	nsleep(dly_ns);
}

static void bb_stop(void)
{
	set2(0, 0);
	nsleep(dly_ns);
	set2(1, 0);
	nsleep(dly_ns);
	set2(1, 1);
	nsleep(dly_ns);
}

/* octet MSB d'abord, plus le 9e top d'horloge que la puce attend */
static void bb_byte(unsigned b)
{
	int i;

	for (i = 7; i >= 0; i--) {
		int bit = (b >> i) & 1;
		set2(0, bit);
		nsleep(dly_ns);
		set2(1, bit);
		nsleep(dly_ns);
	}
	set2(0, 1);
	nsleep(dly_ns);
	set2(1, 1);
	nsleep(dly_ns);
	set2(0, 1);
	nsleep(dly_ns);
}

static void write_cmd_data(unsigned cmd, unsigned data)
{
	bb_start();
	bb_byte(cmd);
	bb_byte(data);
	bb_stop();
}

/* police 7 segments, DP G F E D C B A */
static unsigned char glyph(char c)
{
	switch (c) {
	case '0': return 0x3f;
	case '1': return 0x06;
	case '2': return 0x5b;
	case '3': return 0x4f;
	case '4': return 0x66;
	case '5': return 0x6d;
	case '6': return 0x7d;
	case '7': return 0x07;
	case '8': return 0x7f;
	case '9': return 0x6f;
	case 'A': case 'a': return 0x77;
	case 'b': case 'B': return 0x7c;
	case 'C': return 0x39;
	case 'c': return 0x58;
	case 'd': case 'D': return 0x5e;
	case 'E': case 'e': return 0x79;
	case 'F': case 'f': return 0x71;
	case 'H': case 'h': return 0x76;
	case 'L': return 0x38;
	case 'n': return 0x54;
	case 'o': case 'O': return 0x5c;
	case 'P': case 'p': return 0x73;
	case 'r': return 0x50;
	case 't': return 0x78;
	case 'U': case 'u': return 0x3e;
	case 'y': return 0x6e;
	case '-': return 0x40;
	case '_': return 0x08;
	case ' ': return 0x00;
	default: return 0x00;
	}
}

static void usage(void)
{
	fprintf(stderr,
		"usage: fd6xx [--chip DEV] [--clk N] [--dat N] [--brightness 0-7]\n"
		"             [--delay NS] [--push-pull] [--ltr] <commande>\n"
		"\n"
		"commandes:\n"
		"  write <texte>    affiche jusqu'a 5 caracteres, de gauche a droite\n"
		"  seg <hex>...     octets de segments bruts, de droite a gauche\n"
		"  blank            eteint les chiffres\n"
		"  test             allume tous les segments\n"
		"\n"
		"  --push-pull      sortie franche au lieu d'open-drain + pull-up\n"
		"                   (requis par les cartes sans pull-up, Transpeed)\n"
		"  --ltr            l'adresse 0x68 est le chiffre de gauche\n"
		"\n"
		"defauts : --chip /dev/gpiochip1 --clk 226 --dat 227 (H96 : PH2/PH3)\n");
	exit(2);
}

int main(int argc, char **argv)
{
	const char *chip = "/dev/gpiochip1";
	int clk = 226, dat = 227, brightness = 3;
	int i, argi = 1, push_pull = 0, ltr = 0;

	while (argi < argc && !strncmp(argv[argi], "--", 2)) {
		const char *opt = argv[argi++];
		const char *val;

		if (!strcmp(opt, "--push-pull")) {
			push_pull = 1;
			continue;
		}
		if (!strcmp(opt, "--ltr")) {
			ltr = 1;
			continue;
		}
		val = (argi < argc) ? argv[argi++] : NULL;

		if (!val) {
			fprintf(stderr, "fd6xx: %s attend une valeur\n", opt);
			return 2;
		}
		if (!strcmp(opt, "--chip"))
			chip = val;
		else if (!strcmp(opt, "--clk"))
			clk = atoi(val);
		else if (!strcmp(opt, "--dat"))
			dat = atoi(val);
		else if (!strcmp(opt, "--brightness"))
			brightness = atoi(val) & 7;
		else if (!strcmp(opt, "--delay"))
			dly_ns = atol(val);
		else {
			fprintf(stderr, "fd6xx: option inconnue %s\n", opt);
			return 2;
		}
	}
	if (argi >= argc)
		usage();

	gfd = open(chip, O_RDWR | O_CLOEXEC);
	if (gfd < 0)
		die(chip);

	/* open-drain + pull-up : jamais de haut pousse, la ligne remonte.
	 * push-pull : le vendor Allwinner pilote en sortie franche (les cartes
	 * sans pull-up externe, comme la Transpeed, ne marchent que comme ca). */
	struct gpio_v2_line_request req;
	unsigned long long flagsets[] = {
		GPIO_V2_LINE_FLAG_OUTPUT | GPIO_V2_LINE_FLAG_OPEN_DRAIN |
			GPIO_V2_LINE_FLAG_BIAS_PULL_UP,
		GPIO_V2_LINE_FLAG_OUTPUT | GPIO_V2_LINE_FLAG_OPEN_DRAIN,
		GPIO_V2_LINE_FLAG_OUTPUT,
	};
	int first = push_pull ? 2 : 0;
	int last = push_pull ? 3 : 2;
	int chosen = -1;
	for (i = first; i < last; i++) {
		memset(&req, 0, sizeof(req));
		req.num_lines = 2;
		req.offsets[0] = clk;
		req.offsets[1] = dat;
		req.config.flags = flagsets[i];
		strncpy(req.consumer, "fd6xx", sizeof(req.consumer) - 1);
		if (ioctl(gfd, GPIO_V2_GET_LINE_IOCTL, &req) == 0) {
			chosen = i;
			break;
		}
	}
	if (chosen < 0)
		die("GPIO_V2_GET_LINE_IOCTL");
	reqfd = req.fd;

	write_cmd_data(CMD_CTRL, (((brightness + 1) & 7) << 4) | 0x01);

	const char *cmd = argv[argi++];

	if (!strcmp(cmd, "write")) {
		const char *text = (argi < argc) ? argv[argi] : "";
		int n = (int)strlen(text);
		unsigned char grids[MAX_GRIDS] = { 0 };

		if (n > MAX_GRIDS)
			n = MAX_GRIDS;
		/* H96 : 0x68 = chiffre le plus a droite ; Transpeed : le plus a
		 * gauche (mesure a l'ecran). --ltr choisit le second. */
		for (i = 0; i < n; i++)
			grids[i] = glyph(text[ltr ? i : n - 1 - i]);
		for (i = 0; i < MAX_GRIDS; i++)
			write_cmd_data(ADDR_BASE + 2 * i, grids[i]);
	} else if (!strcmp(cmd, "seg")) {
		for (i = 0; i < MAX_GRIDS; i++) {
			unsigned v = (argi + i < argc) ?
					     (unsigned)strtoul(argv[argi + i], NULL, 0) :
					     0;
			write_cmd_data(ADDR_BASE + 2 * i, v & 0xff);
		}
	} else if (!strcmp(cmd, "blank")) {
		for (i = 0; i < MAX_GRIDS; i++)
			write_cmd_data(ADDR_BASE + 2 * i, 0x00);
	} else if (!strcmp(cmd, "test")) {
		for (i = 0; i < MAX_GRIDS; i++)
			write_cmd_data(ADDR_BASE + 2 * i, 0xff);
	} else {
		usage();
	}

	return 0;
}
