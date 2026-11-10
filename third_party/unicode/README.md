# Unicode Character Database 17.0.0

`ucd-17.0.0` holds unmodified copies of `UnicodeData.txt` and `SpecialCasing.txt` from https://www.unicode.org/Public/17.0.0/ucd/ and of the Unicode License v3 from https://www.unicode.org/license.txt as `license.txt`. The files are data only.

`tools/gen_lower_table.py` generates `src/text/lower_table.odin` from the two data files:

```sh
python3 -I tools/gen_lower_table.py third_party/unicode/ucd-17.0.0 src/text/lower_table.odin
```

`proofs/text/verify.py` compares that table and the Lean model's lower-casing with the same files over every code point and refuses copies whose SHA-256 differs from these values:

| File | SHA-256 |
| --- | --- |
| `UnicodeData.txt` | `2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c` |
| `SpecialCasing.txt` | `efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588` |

The licence terms are reproduced in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
