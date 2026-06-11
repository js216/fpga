# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jakob Kastelic
# Per-clock constraints for sport_rx N=4: the UART/printer domain runs at
# 12 MHz and must not be held to the lane bit-clock target.
ctx.addClock("clk12$SB_IO_IN_$glb_clk", 12)
for i in range(4):
    ctx.addClock("aclk_in[%d]$SB_IO_IN_$glb_clk" % i, 65)
