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
        echo "https://via.placeholder.com/${width}x${height}.png/CC0000/FFFFFF?text=CHART+RENDER+FAILED"
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

# === BAR CHART DATA ===
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
  if [[ -z "$engine" ]]; then continue; fi
  
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
      "borderWidth": 3,
      "borderColor": "#ffffff"
    }]
  },
  "options": {
    "cutout": "65%",
    "plugins": {
      "title": {
        "display": true,
        "text": "Backup Status Overview",
        "color": "#4B286D",
        "font": { "size": 18, "weight": "bold" }
      },
      "legend": {
        "position": "bottom",
        "labels": { "color": "#4B286D", "font": { "weight": "bold" } }
      },
      "datalabels": {
        "display": true,
        "color": "#4B286D",
        "font": { "size": 16, "weight": "bold" },
        "formatter": "(ctx, data) => data.chart.data.labels[ctx.dataIndex].split(' ')[1]"
      }
    }
  },
  "plugins": ["chartjs-plugin-datalabels"]
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
      "borderRadius": 12,
      "borderSkipped": false,
      "barPercentage": 0.7,
      "categoryPercentage": 0.6
    }]
  },
  "options": {
    "layout": { "padding": { "top": 30, "bottom": 10 } },
    "plugins": {
      "title": {
        "display": true,
        "text": "Daily Backup Storage by DB Engine",
        "color": "#4B286D",
        "font": { "size": 20, "weight": "bold" }
      },
      "legend": { "display": false },
      "datalabels": {
        "display": true,
        "anchor": "end",
        "align": "end",
        "offset": 4,
        "color": "#4B286D",
        "font": { "weight": "bold", "size": 13 },
        "formatter": "(value) => value + ' GB'"
      }
    },
    "scales": {
      "x": {
        "ticks": {
          "color": "#4B286D",
          "font": { "weight": "bold" }
        },
        "grid": { "display": false },
        "title": { "display": false }
      },
      "y": {
        "beginAtZero": true,
        "title": {
          "display": true,
          "text": "Storage (GB)",
          "color": "#4B286D",
          "font": { "weight": "bold" }
        },
        "ticks": { "color": "#333333" },
        "grid": { "color": "rgba(200,200,200,0.2)" }
      }
    }
  },
  "plugins": ["chartjs-plugin-datalabels"]
}
EOF
)

BAR_CHART_URL=$(post_chart_json "${BAR_CHART_JSON}" 600 350 white)

# === TOP 5 BACKUPS ===
top_backups=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "
SELECT Server, DB_engine, CONCAT(ROUND(SUM(
  CASE size_name
    WHEN 'B'  THEN size / 1024 / 1024
    WHEN 'KB' THEN size / 1024
    WHEN 'MB' THEN size
    WHEN 'GB' THEN size * 1024
    ELSE 0
  END
), 2), ' MB') AS TotalSize
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY Server, DB_engine
ORDER BY SUM(
  CASE size_name
    WHEN 'B'  THEN size / 1024 / 1024
    WHEN 'KB' THEN size / 1024
    WHEN 'MB' THEN size
    WHEN 'GB' THEN size * 1024
    ELSE 0
  END
) DESC
LIMIT 5;
")

# === EMAIL HTML ===
{
echo "<!DOCTYPE html><html><head><meta charset='UTF-8'><style>
body { font-family: 'Helvetica Neue', Arial, sans-serif; background-color: #f4f4f4; color: #333; padding: 20px; }
.container { max-width: 800px; margin: auto; background-color: #fff; padding: 20px; border-radius: 10px; box-shadow: 0 0 12px rgba(75, 40, 109, 0.1); }
h1, h2, h3 { color: #4B286D; text-align: center; }
table { width: 100%; border-collapse: collapse; margin-top: 20px; border: 1px solid #e0d6f0; border-radius: 8px; overflow: hidden; box-shadow: 0 0 8px rgba(0,0,0,0.05); }
th { background-color: #4B286D; color: white; padding: 10px; text-align: left; }
td { padding: 10px; border-bottom: 1px solid #eee; }
tr:nth-child(even) { background-color: #f9f9f9; }
.chart-frame { border: 1px solid #e0d6f0; border-radius: 12px; padding: 15px; box-shadow: 0 0 12px rgba(0,0,0,0.05); background-color: #fff; }
</style></head><body><div class='container'>"

echo "<h1>Daily Backup Report - ${REPORT_DATE}</h1>"
echo "<div style='padding: 15px; background-color: #f7f3fb; border-left: 5px solid #4B286D; margin-bottom: 20px;'>"
echo "<p><strong>Executive Summary:</strong><br>"
echo "<span style='color: #008000;'>Status: HIGH SUCCESS (${success_rate}%)</span> | Total Failures: ${error_count} | Total Storage: ${total_storage} GB</p>"
echo "</div>"

echo "<table><tr><td class='chart-frame' style='width: 50%; text-align: center;'><img src='${DONUT_CHART_URL}' style='max-width: 100%; border-radius: 12px;'></td>"
echo "<td class='chart-frame' style='width: 50%; text-align: center;'><img src='${BAR_CHART_URL}' style='max-width: 100%; border-radius: 12px;'></td></tr></table>"

echo "<h2>Top 5 Largest Backups</h2><table><tr><th>Server</th><th>Database Engine</th><th>Size</th></tr>"
echo "${top_backups}" | tail -n +2 | while IFS=$'\t' read -r server engine size; do
    echo "<tr><td>${server}</td><td>${engine}</td><td>${size}</td></tr>"
done
echo "</table>"

echo "<div style='text-align: center; margin-top: 30px; color: #4B286D;'>Report generated by Database Engineering</div>"
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

echo " Email sent successfully to yvette.halili@telusinternational.com"
