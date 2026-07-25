#!/bin/bash
# Shares this machine's trackpad/keyboard with the Arch PC.
# protocol=barrier is required: deskflow's native protocol (Synergy 1.8) makes
# waynergy on the PC fail with a protocol error, and older deskflow builds crash
# outright with XInvalidProtocol.
exec deskflow-server -c "$HOME/.config/deskflow/deskflow-server.conf" \
     -n chromebook -f --address :24800
