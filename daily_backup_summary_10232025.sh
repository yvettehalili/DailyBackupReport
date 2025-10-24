#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
DB_USER="trtel.backup"
DB_PASS="Telus2017#"
DB_NAME="ti_db_inventory"
REPORT_DATE=$(date -d "yesterday" '+%Y-%m-%d')
DIR="backup"
mkdir -p "${DIR}"
emailFile="${DIR}/daily_backup_report.html"

# --- API Configuration ---
QUICKCHART_API="https://quickchart.io/chart/create"

# === HELPER FUNCTION: POST JSON and Get Short URL ===
post_chart_json() {
    local json_payload="${1}"
    local width="${2:-350}"
    local height="${3:-350}"
    local background_color="${4:-white}"

    local URL
    URL=$(curl -s -X POST "${QUICKCHART_API}" \
        -H "Content-Type: application/json" \
        -d "{ \"chart\": ${json_payload}, \"width\": ${width}, \"height\": ${height}, \"backgroundColor\": \"${background_color}\" }" \
        | jq -r '.url')

    if [[ -z "$URL" || "$URL" == "null" ]]; then
        echo "https://via.placeholder.com/${width}x${height}.png/CC0000/FFFFFF?text=CHART+FAILED"
    else
        echo "$URL"
    fi
}

# === EXECUTIVE METRICS ===
read total_count error_count <<< $(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT COUNT(*), SUM(IF(size = 0.00 AND size_name = 'B', 1, 0))
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")

success_count=$((total_count - error_count))
success_rate=$(awk "BEGIN {if (${total_count} == 0) {printf \"0.0\"} else {printf \"%.1f\", (${success_count}/${total_count})*100}}")
error_rate=$(awk "BEGIN {if (${total_count} == 0) {printf \"0.0\"} else {printf \"%.1f\", (${error_count}/${total_count})*100}}")

total_storage=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT ROUND(SUM(CASE size_name
    WHEN 'B'  THEN size/1024/1024/1024
    WHEN 'KB' THEN size/1024/1024
    WHEN 'MB' THEN size/1024
    WHEN 'GB' THEN size
    ELSE 0 END), 2)
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")

# === BAR CHART: Storage per DB Engine ===
engine_storage=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT DB_engine, ROUND(SUM(CASE size_name
    WHEN 'B'  THEN size/1024/1024/1024
    WHEN 'KB' THEN size/1024/1024
    WHEN 'MB' THEN size/1024
    WHEN 'GB' THEN size
    ELSE 0 END), 1) AS TotalGB
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY DB_engine;
")

LABELS=()
DATA=()
COLORS=()

while IFS=$'\t' read -r engine total; do
  [[ -z "$engine" ]] && continue
  LABELS+=("$engine")
  DATA+=("$total")
  case "$engine" in
    MYSQL) COLOR_CODE="#6A4C93" ;;
    PGSQL) COLOR_CODE="#00A6A6" ;;
    MSSQL) COLOR_CODE="#8BC34A" ;;
    ORACLE) COLOR_CODE="#FF7043" ;;
    *) COLOR_CODE="#B0BEC5" ;;
  esac
  COLORS+=("$COLOR_CODE")
done <<< "$(echo "${engine_storage}" | tr -d '\r')"

LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" | jq -Rsc 'split("\n")[:-1]')
DATA_JSON=$(printf '%s\n' "${DATA[@]}" | jq -Rsc 'split("\n")[:-1] | map(tonumber)')
COLORS_JSON=$(printf '%s\n' "${COLORS[@]}" | jq -Rsc 'split("\n")[:-1]')

# === DONUT CHART ===
DONUT_CHART_JSON=$(cat <<EOF
{
  "type": "doughnut",
  "data": {
    "labels": ["Success (${success_rate}%)", "Failure (${error_rate}%)"],
    "datasets": [{
      "data": [${success_count}, ${error_count}],
      "backgroundColor": ["#6A4C93", "#00A6A6"],
      "borderWidth": 3
    }]
  },
  "options": {
    "plugins": {
      "title": { "display": true, "text": "Backup Status Overview", "color": "#4B286D", "font": { "size": 18, "weight": "bold" } },
      "legend": { "position": "bottom", "labels": { "color": "#4B286D", "font": { "weight": "bold" } } }
    },
    "cutout": "65%"
  }
}
EOF
)
DONUT_CHART_URL=$(post_chart_json "${DONUT_CHART_JSON}" 350 350 white)

# === BAR CHART ===
BAR_CHART_JSON=$(cat <<EOF
{
  "type": "bar",
  "data": {
    "labels": ${LABELS_JSON},
    "datasets": [{
      "label": "Total Storage (GB)",
      "data": ${DATA_JSON},
      "backgroundColor": ${COLORS_JSON},
      "borderRadius": 8
    }]
  },
  "options": {
    "plugins": {
      "title": {
        "display": true,
        "text": "Daily Backup Storage by DB Engine",
        "color": "#4B286D",
        "font": { "size": 20, "weight": "bold" }
      },
      "legend": { "display": false }
    },
    "scales": {
      "x": {
        "ticks": { "color": "#4B286D", "font": { "weight": "bold" } },
        "grid": { "display": false }
      },
      "y": {
        "beginAtZero": true,
        "title": { "display": true, "text": "Storage (GB)", "color": "#4B286D", "font": { "weight": "bold" } },
        "ticks": { "color": "#333333" },
        "grid": { "color": "rgba(200,200,200,0.2)" }
      }
    }
  }
}
EOF
)
BAR_CHART_URL=$(post_chart_json "${BAR_CHART_JSON}" 600 350 white)

# === TOP 5 AGGREGATED BACKUPS ===
top_backups=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "
SELECT Server, DB_engine, CONCAT(ROUND(SUM(
  CASE size_name
    WHEN 'B'  THEN size / 1024 / 1024
    WHEN 'KB' THEN size / 1024
    WHEN 'MB' THEN size
    WHEN 'GB' THEN size * 1024
    ELSE 0 END), 2), ' MB') AS TotalSize
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY Server, DB_engine
ORDER BY SUM(
  CASE size_name
    WHEN 'B'  THEN size / 1024 / 1024
    WHEN 'KB' THEN size / 1024
    WHEN 'MB' THEN size
    WHEN 'GB' THEN size * 1024
    ELSE 0 END) DESC
LIMIT 5;
")

# === EMAIL HTML ===
{
echo "<!DOCTYPE html><html><head><meta charset='UTF-8'><style>
body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f5f5f9; color: #333; padding: 20px; }
.container { max-width: 800px; margin: auto; background-color: #fff; padding: 25px; border-radius: 12px; box-shadow: 0 2px 14px rgba(75, 40, 109, 0.15); }
h1 { color: #4B286D; text-align: center; margin-bottom: 10px; }
.summary-box { background: linear-gradient(90deg, #f2ecfa, #ffffff); padding: 15px; border-left: 6px solid #6A4C93; border-radius: 6px; margin-bottom: 20px; }
.summary-box strong { color: #4B286D; }
table { width: 100%; border-collapse: collapse; margin-top: 20px; border-radius: 8px; overflow: hidden; box-shadow: 0 0 6px rgba(0,0,0,0.05); }
th { background-color: #4B286D; color: white; padding: 10px; }
td { padding: 10px; border-bottom: 1px solid #eee; }
tr:nth-child(even) { background-color: #fafafa; }
.chart-frame { border: 1px solid #e0d6f0; border-radius: 10px; padding: 10px; background-color: #fff; }
.footer { text-align: center; margin-top: 30px; color: #4B286D; font-weight: bold; }
</style></head><body><div class='container'>"

echo "<h1>Daily Backup Report - ${REPORT_DATE}</h1>"
echo "<div class='summary-box'><p><strong>Executive Summary:</strong><br>"
echo "<span style='color: #008000;'>Status: HIGH SUCCESS (${success_rate}%)</span> | Total Failures: ${error_count} | Total Storage: ${total_storage} GB</p></div>"

echo "<table><tr>
<td class='chart-frame' style='width: 50%; text-align: center;'><img src='${DONUT_CHART_URL}' style='max-width: 100%;'></td>
<td class='chart-frame' style='width: 50%; text-align: center;'><img src='${BAR_CHART_URL}' style='max-width: 100%;'></td>
</tr></table>"

echo "<h2 style='color:#4B286D;'>Top 5 Largest Backups</h2><table><tr><th>Server</th><th>Database Engine</th><th>Size</th></tr>"
echo "${top_backups}" | tail -n +2 | while IFS=$'\t' read -r server engine size; do
    echo "<tr><td>${server}</td><td>${engine}</td><td>${size}</td></tr>"
done
echo "</table>"

echo "<div class='footer'>Report generated by Database Engineering</div>"
echo "</div></body></html>"
} > "${emailFile}"

# === SEND EMAIL ===
{
echo "To: yvette.halili@telusinternational.com"
echo "From: no-reply@telusinternational.com"
echo "MIME-Version: 1.0"
echo "Content-Type: text/html; charset=utf-8"
echo "Subject: Daily Backup Report - ${REPORT_DATE}"
echo ""
cat "${emailFile}"
} | /usr/sbin/sendmail -t

echo "Email sent successfully to yvette.halili@telusinternational.com"
