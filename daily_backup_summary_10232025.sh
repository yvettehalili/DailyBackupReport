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

QUICKCHART_API="https://quickchart.io/chart/create"

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

# === METRICS ===
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

# === BAR CHART ===
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
    MYSQL) COLOR="#6A4C93" ;;
    PGSQL) COLOR="#00A6A6" ;;
    MSSQL) COLOR="#8BC34A" ;;
    ORACLE) COLOR="#FF7043" ;;
    *) COLOR="#B0BEC5" ;;
  esac
  COLORS+=("$COLOR")
done <<< "$(echo "${engine_storage}" | tr -d '\r')"

LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" | jq -Rsc 'split("\n")[:-1]')
DATA_JSON=$(printf '%s\n' "${DATA[@]}" | jq -Rsc 'split("\n")[:-1] | map(tonumber)')
COLORS_JSON=$(printf '%s\n' "${COLORS[@]}" | jq -Rsc 'split("\n")[:-1]')

DONUT_JSON=$(cat <<EOF
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
      "title": { "display": true, "text": "Backup Status Overview", "color": "#4B286D", "font": {"size": 18, "weight": "bold"} },
      "legend": { "position": "bottom", "labels": {"color": "#4B286D", "font": {"weight": "bold"}} }
    },
    "cutout": "65%"
  }
}
EOF
)
DONUT_CHART_URL=$(post_chart_json "${DONUT_JSON}" 350 350 white)

BAR_JSON=$(cat <<EOF
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
      "title": { "display": true, "text": "Total Backup Sizes by Database Type", "color": "#4B286D", "font": {"size": 18, "weight": "bold"} },
      "legend": { "display": false }
    },
    "scales": {
      "x": { "ticks": { "color": "#4B286D", "font": {"weight": "bold"} }, "grid": {"display": false} },
      "y": { "beginAtZero": true, "ticks": {"color": "#333"}, "grid": {"color": "rgba(200,200,200,0.2)"} }
    }
  }
}
EOF
)
BAR_CHART_URL=$(post_chart_json "${BAR_JSON}" 600 350 white)

# === TOP 5 ===
top_backups=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "
SELECT Server, DB_engine, CONCAT(ROUND(SUM(
  CASE size_name
    WHEN 'B'  THEN size / 1024 / 1024 / 1024
    WHEN 'KB' THEN size / 1024 / 1024
    WHEN 'MB' THEN size / 1024
    WHEN 'GB' THEN size
    ELSE 0 END
), 2), ' GB') AS TotalSize
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY Server, DB_engine
ORDER BY SUM(
  CASE size_name
    WHEN 'B'  THEN size / 1024 / 1024 / 1024
    WHEN 'KB' THEN size / 1024 / 1024
    WHEN 'MB' THEN size / 1024
    WHEN 'GB' THEN size
    ELSE 0 END
) DESC
LIMIT 5;
")

TOP_5_TABLE=$(echo "<table><tr><th>Server</th><th>Database Engine</th><th>Size (GB)</th></tr>"; \
echo "${top_backups}" | tail -n +2 | while IFS=$'\t' read -r s e sz; do \
  echo "<tr><td>${s}</td><td>${e}</td><td>${sz}</td></tr>"; \
done; echo "</table>")

# === HTML REPORT ===
cat <<EOF > "${emailFile}"
<html>
<head>
<style>
  body {
    font-family: 'Segoe UI', Arial, sans-serif;
    background-color: #fafafa;
    color: #333;
    padding: 20px;
  }
  h2 {
    text-align: center;
    color: #2b3d52;
    margin-bottom: 25px;
  }
  .summary-box {
    background: #f3f1fa;
    border: 1px solid #ddd;
    border-radius: 12px;
    box-shadow: 0 0 10px rgba(0,0,0,0.05);
    padding: 20px;
    display: flex;
    justify-content: space-around;
    margin: 0 auto 30px;
    max-width: 800px;
  }
  .metric {
    text-align: center;
    flex: 1;
  }
  .metric-value {
    font-size: 22px;
    font-weight: bold;
    color: #4B286D;
  }
  .metric-label {
    font-size: 13px;
    font-weight: bold;
    color: #666;
    margin-top: 5px;
  }
  .charts-wrapper {
    background: #fff;
    border-radius: 12px;
    border: 1px solid #e1e1e1;
    box-shadow: 0 0 10px rgba(0,0,0,0.05);
    padding: 20px;
    max-width: 1000px;
    margin: 0 auto 40px;
  }
  .charts-row {
    display: flex;
    justify-content: space-between;
    gap: 20px;
    text-align: center;
  }
  .chart-card {
    flex: 1;
    background: #fff;
    border-radius: 12px;
    border: 1px solid #ddd;
    box-shadow: 0 2px 8px rgba(0,0,0,0.05);
    padding: 15px;
  }
  .chart-title {
    font-weight: bold;
    color: #4B286D;
    margin-bottom: 10px;
  }
  table {
    border-collapse: collapse;
    width: 100%;
    margin-top: 25px;
    font-size: 13px;
  }
  th, td {
    padding: 8px 10px;
    text-align: left;
  }
  th {
    background-color: #4B286D;
    color: #fff;
  }
  td {
    color: #2b3d52;
  }
  tr:nth-child(even) { background-color: #f9f9f9; }
  .footer {
    text-align: center;
    color: #888;
    font-size: 12px;
    margin-top: 30px;
  }
</style>
</head>
<body>

  <h2>📦 Backup Summary - ${REPORT_DATE}</h2>

  <div class="summary-box">
    <div class="metric">
      <div class="metric-value">${TOTAL_SIZE_GB} GB</div>
      <div class="metric-label">Total Storage</div>
    </div>
    <div class="metric">
      <div class="metric-value">${error_count}</div>
      <div class="metric-label">Failures</div>
    </div>
    <div class="metric">
      <div class="metric-value">${success_rate}%</div>
      <div class="metric-label">Success Rate</div>
    </div>
  </div>

  <div class="charts-wrapper">
    <div class="charts-row">
      <div class="chart-card">
        <div class="chart-title">Backup Status Overview</div>
        <img src="${DONUT_CHART_URL}" width="350" height="350">
      </div>
      <div class="chart-card">
        <div class="chart-title">Total Backup Sizes by Database Type</div>
        <div style="font-size:13px;color:#0078d7;margin-bottom:5px;">Total: ${TOTAL_SIZE_GB} GB</div>
        <img src="${BAR_CHART_URL}" width="500" height="350">
      </div>
    </div>
    <h3 style="text-align:center; color:#4B286D; margin-top:25px;">Top 5 Largest Backups</h3>
    ${TOP_5_TABLE}
  </div>

  <div class="footer">
    Report generated by Database Engineering
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

echo "✅ Email sent successfully to yvette.halili@telusinternational.com"
