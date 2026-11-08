/* SPDX-License-Identifier: GPL-2.0-only */
/* Shim : remplace <sunxi-sid.h> du BSP, absent du noyau mainline.
 *
 * Les deux symboles ne servent qu'a deux endroits :
 *  - sunxi_get_soc_ver() : uniquement pour la propriete DT `delay-maps`,
 *    que cette carte n'utilise pas -> 0 est sans effet ;
 *  - sunxi_efuse_readn() : lecture de la calibration EPHY "ft_zone" par
 *    sunxi-ephy.c. Non implementable hors BSP : on renvoie -ENODEV, le
 *    driver retombe sur sa valeur par defaut (0x1084).
 * EFUSE_FTCP_NAME n'est qu'un nom de cle, il doit exister a la compilation.
 */
#ifndef _SHIM_SUNXI_SID_H
#define _SHIM_SUNXI_SID_H

#include <linux/errno.h>
#include <linux/types.h>

#define EFUSE_FTCP_NAME "ft_zone"

static inline int sunxi_efuse_readn(const char *name, void *buf, size_t len)
{
	return -ENODEV;
}

static inline u32 sunxi_get_soc_ver(void)
{
	return 0;
}

#endif
