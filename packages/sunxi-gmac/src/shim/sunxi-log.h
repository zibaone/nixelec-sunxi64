/* SPDX-License-Identifier: GPL-2.0-only */
/* Shim : remplace <sunxi-log.h> du BSP (AW_BSP), absent du noyau mainline.
 * Le BSP passe un struct device en premier argument partout. */
#ifndef _SHIM_SUNXI_LOG_H
#define _SHIM_SUNXI_LOG_H

#include <linux/device.h>

#define sunxi_err(dev, fmt, ...)   dev_err(dev, fmt, ##__VA_ARGS__)
#define sunxi_warn(dev, fmt, ...)  dev_warn(dev, fmt, ##__VA_ARGS__)
#define sunxi_info(dev, fmt, ...)  dev_info(dev, fmt, ##__VA_ARGS__)
#define sunxi_debug(dev, fmt, ...) dev_dbg(dev, fmt, ##__VA_ARGS__)

#endif
