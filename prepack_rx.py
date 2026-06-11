# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jakob Kastelic
# Per-clock constraints for sport_rx builds: the UART/printer domain
# runs at 12 MHz; the lane bit-clock domains get an aggressive target so
# the receive/arm cone is placed with real slack (lazy closure at the
# actual 60.8 MHz left it per-run marginal).
ctx.addClock("clk12$SB_IO_IN_$glb_clk", 12)
for i in range(4):
    ctx.addClock("aclk_in[%d]$SB_IO_IN_$glb_clk" % i, 75)
ctx.addClock("aclk_in$SB_IO_IN_$glb_clk", 75)
