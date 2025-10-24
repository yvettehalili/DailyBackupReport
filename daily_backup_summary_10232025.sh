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

# === HELPER FUNCTION ===
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
TOTAL_SIZE_GB="${total_storage}"

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

# === 1. DONUT CHART ===
DONUT_CHART_JSON=$(cat <<EOF
{
  "type": "doughnut",
  "data": {
    "labels": ["Success (${success_rate}%)", "Failure (${error_rate}%)"],
    "datasets": [{
      "data": [${success_count}, ${error_count}],
      "backgroundColor": ["#6A4C93", "#00A6A6"],
      "borderWidth": 2
    }]
  },
  "options": {
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
      }
    },
    "cutout": "65%"
  }
}
EOF
)
DONUT_CHART_URL=$(post_chart_json "${DONUT_CHART_JSON}" 350 350 white)

# === 2. BAR CHART ===
BAR_CHART_JSON=$(cat <<EOF
{
  "type": "bar",
  "data": {
    "labels": ${LABELS_JSON},
    "datasets": [{
      "label": "Total Storage (GB)",
      "data": ${DATA_JSON},
      "backgroundColor": ${COLORS_JSON},
      "borderRadius": 10
    }]
  },
  "options": {
    "plugins": {
      "title": {
        "display": true,
        "text": "Total Backup Sizes by Database Type",
        "color": "#4B286D",
        "font": { "size": 20, "weight": "bold" }
      },
      "legend": { "display": false },
      "datalabels": {
        "display": true,
        "color": "#333333",
        "anchor": "end",
        "align": "top",
        "font": { "weight": "bold", "size": 12 },
        "formatter": "function(value) { return value + ' GB'; }"
      }
    },
    "scales": {
      "x": {
        "ticks": {
          "color": "#4B286D",
          "font": { "weight": "bold" }
        },
        "grid": { "display": false }
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
  }
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

TOP_5_TABLE=$(echo "<table><tr><th>Server</th><th>Database Engine</th><th>Size</th></tr>"; \
echo "${top_backups}" | tail -n +2 | while IFS=$'\t' read -r server engine size; do \
  echo "<tr><td>${server}</td><td>${engine}</td><td>${size}</td></tr>"; \
done; echo "</table>")

# === HTML REPORT ===
cat <<EOF > "${emailFile}"
<html>
<head>
<style>
  body {
    font-family: 'Segoe UI', Arial, sans-serif;
    color: #333;
    background-color: #fafafa;
    margin: 0;
    padding: 20px;
  }
  .header-box {
    display: flex;
    justify-content: space-around;
    background: #fff;
    border-radius: 12px;
    box-shadow: 0 0 10px rgba(0,0,0,0.05);
    padding: 15px;
    margin-bottom: 30px;
  }
  .metric {
    text-align: center;
  }
  .metric-value {
    font-size: 22px;
    font-weight: bold;
  }
  .metric-label {
    font-size: 13px;
    color: #666;
  }
  .success { color: #2e7d32; }
  .fail { color: #d32f2f; }
  .neutral { color: #1976d2; }
  h2 {
    color: #2b3d52;
    text-align: center;
    margin-bottom: 30px;
  }
  .chart-title {
    font-weight: 600;
    color: #2b3d52;
    text-align: center;
    margin-top: 10px;
    margin-bottom: 10px;
    font-size: 16px;
  }
  .chart-container {
    text-align: center;
    margin-bottom: 40px;
  }
  .total {
    font-size: 16px;
    font-weight: bold;
    color: #0078d7;
    text-align: center;
    margin-bottom: 10px;
  }
  table {
    border-collapse: collapse;
    width: 80%;
    margin: 0 auto;
    background: #fff;
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 0 10px rgba(0,0,0,0.05);
  }
  th, td {
    padding: 12px 16px;
    text-align: left;
  }
  th {
    background-color: #2b3d52;
    color: #fff;
    font-size: 14px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }
  tr:nth-child(even) { background-color: #f8f9fa; }
  tr:hover { background-color: #eef2f7; }
  td { color: #333; font-size: 13px; }
  td:first-child { font-weight: 600; color: #0078d7; }
  .footer {
    font-size: 11px;
    color: #666;
    text-align: center;
    margin-top: 30px;
  }
</style>
</head>
<body>
  <h2>📦 Daily Backup Summary Report - ${REPORT_DATE}</h2>

  <div class="header-box">
    <div class="metric">
      <div class="metric-value neutral">${total_count}</div>
      <div class="metric-label">Total Backups</div>
    </div>
    <div class="metric">
      <div class="metric-value neutral">${TOTAL_SIZE_GB} GB</div>
      <div class="metric-label">Total Storage</div>
    </div>
    <div class="metric">
      <div class="metric-value fail">${error_count}</div>
      <div class="metric-label">Failures</div>
    </div>
    <div class="metric">
      <div class="metric-value success">${success_rate}%</div>
      <div class="metric-label">Success Rate</div>
    </div>
  </div>

  <div class="chart-container">
    <div class="chart-title">Backup Status Overview</div>
    <img src="${DONUT_CHART_URL}" width="400" height="400">
  </div>

  <div class="chart-container">
    <div class="chart-title">Total Backup Sizes by Database Type</div>
    <div class="total">Total Backup Size: ${TOTAL_SIZE_GB} GB</div>
    <img src="${BAR_CHART_URL}" width="600" height="350">
  </div>

  <h3 style="text-align:center; color:#2b3d52;">Top 5 Largest Backups</h3>
  ${TOP_5_TABLE}

  <div class="footer">
    Report generated on $(date '+%B %d, %Y %I:%M %p') by Database Engineering
  </div>
</body>
</html>
EOF

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
