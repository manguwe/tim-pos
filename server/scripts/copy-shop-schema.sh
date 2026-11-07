#!/bin/sh
# Refreshes the report engine's copies of the phone code after tools/ changes. Run from server/.
set -e
cp ../tools/src/reports.ts ../tools/src/money.ts src/reports/
python3 - <<'PY'
import re
s=open('../app/assets/sql/local_schema.sql').read()
blocks=[b.strip() for b in re.split(r'^-- ##\s*$',s,flags=re.M)]
keep=[]
for b in blocks:
    b2='\n'.join(l for l in b.split('\n') if not l.startswith('-- ')).strip()
    if b2.startswith(('create table','create index','create unique index','create trigger "stock_movements_level"')): keep.append(b2)
open('src/reports/shop_schema.sql','w').write('-- Copy of the phone schema (tables, indexes and the stock-level trigger only). Made by scripts/copy-shop-schema.sh. Do not edit by hand.\n-- ##\n'+'\n-- ##\n'.join(keep)+'\n')
PY
