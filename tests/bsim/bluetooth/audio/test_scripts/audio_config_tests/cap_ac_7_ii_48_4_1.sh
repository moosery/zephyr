#!/usr/bin/env bash
# Copyright (c) 2025 Nordic Semiconductor ASA
# SPDX-License-Identifier: Apache-2.0

source $(dirname "$0")/_ac_common.sh

ac_config=7_ii ac_tx_preset=48_4_1 ac_rx_preset=48_4_1 ac_acc_cnt=2 Execute_cap_unicast_ac $@
