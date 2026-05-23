#!/usr/bin/env bash
# Usage: curlresponse.sh <URL> [COUNT]
# Description: Measure response time of a web server
# Dependencies: curl

set -eu

URL="$1"
COUNT="${2:-100}"
OUT_FILE="curlresponse-$(date +%FT%H%M%S)"

for _ in $(seq 1 "$COUNT"); do curl -o /dev/null -s -w "%{http_code} %{time_total}\n" "$URL"; done | \
tee  "$OUT_FILE" | \
awk '{http_code[$1]++; sum[$1] += $2; sumsq[$1] += $2*$2}
     END {
         for (c in http_code) {
             mean = sum[c]/http_code[c];
             variance = (sumsq[c]/http_code[c]) - (mean^2);
             print "HTTP Code:         ", c;
             print "Total count:       ", http_code[c];
             print "Response time Mean:", mean;
             print "Variance:          ", variance;
             print "Standard Deviation:", sqrt(variance);
             print "";
         }
     }'
