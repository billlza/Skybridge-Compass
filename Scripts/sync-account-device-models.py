#!/usr/bin/env python3
"""Export the shared Apple hardware catalogue for Windows presentation only."""
import argparse,json,re
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--apple-root',type=Path,required=True);p.add_argument('--check',action='store_true');a=p.parse_args()
source=(a.apple_root/'Sources/SkyBridgeProtocolCore/AccountDevices/AppleHardwareModelCatalog.swift').read_text()
field=source.split('private static let names: [String: String] = [',1)[1].split('\n    ]',1)[0]
names=dict(re.findall(r'"([^"\n]+)": "([^"\n]+)"',field))
if len(names)<50:raise ValueError('Shared model catalogue did not contain its expected names')
result=json.dumps(names,ensure_ascii=False,sort_keys=True,indent=2)+'\n'
target=Path(__file__).resolve().parent.parent/'windows/Skybridge.WinClient/Resources/account-device-apple-models.json'
if a.check:
 if target.read_text()!=result:raise SystemExit('Windows hardware catalogue differs from the shared Apple source')
 print('Account device model catalogue: exact match')
else:target.write_text(result)
