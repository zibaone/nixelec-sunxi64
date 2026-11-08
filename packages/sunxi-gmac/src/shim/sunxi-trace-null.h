/* SPDX-License-Identifier: GPL-2.0-only */
/* Shim : les tracepoints du BSP sont neutralises (non necessaires au portage). */
#ifndef _SHIM_SUNXI_TRACE_NULL_H
#define _SHIM_SUNXI_TRACE_NULL_H

#define trace_sunxi_gmac_rx_desc(...) do { } while (0)
#define trace_sunxi_gmac_tx_desc(...) do { } while (0)
#define trace_sunxi_gmac_skb_dump(...) do { } while (0)

#endif
