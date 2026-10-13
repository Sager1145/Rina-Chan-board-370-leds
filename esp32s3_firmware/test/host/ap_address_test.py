#!/usr/bin/env python3
"""Strict pure address vectors plus production configuration/protocol regressions."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
FW = HERE.parents[1]
with tempfile.TemporaryDirectory(prefix='rina-ap-address-') as directory:
    binary = Path(directory) / 'policy'
    subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined',
                    '-O2', '-I' + str(FW / 'src'), str(HERE / 'ap_address_policy_test.cpp'),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
environment = dict(os.environ, RINA_AUDIT_CASE_SOURCE=str(HERE / 'ap_address_integration_cases.cpp'))
subprocess.run([sys.executable, str(HERE / 'audit_repairs_test.py'),
                'ap_address_defaults', 'ap_address_override', 'ap_address_failures',
                'ap_address_protocol', 'ap_address_restart_ap', 'ap_address_restart_sta'],
               env=environment, check=True)
