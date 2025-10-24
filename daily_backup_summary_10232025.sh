#!/bin/bash

# === CONFIGURATION ===
DB_USER="trtel.backup"
DB_PASS="Telus2017#"
DB_NAME="ti_db_inventory"
REPORT_DATE=$(date -d "yesterday" '+%Y-%m-%d')
DIR="backup"
mkdir -p "${DIR}"
emailFile="${DIR}/daily_backup_report.html"

# === EXECUTIVE METRICS ===
read total_count error_count <<< $(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT COUNT(*), SUM(IF(size = 0.00 AND size_name = 'B', 1, 0))
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")

success_count=$((total_count - error_count))
success_rate=$(awk "BEGIN {printf \"%.1f\", (${success_count}/${total_count})*100}")
error_rate=$(awk "BEGIN {printf \"%.1f\", (${error_count}/${total_count})*100}")

total_storage=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT ROUND(SUM(CASE size_name
    WHEN 'B' THEN size/1024/1024/1024
    WHEN 'KB' THEN size/1024/1024
    WHEN 'MB' THEN size/1024
    WHEN 'GB' THEN size
    ELSE 0 END), 2)
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}';
")

# === DONUT CHART ===
DONUT_CHART_URL="https://quickchart.io/chart?c=$(jq -sRr @uri <<EOF
{
  "type": "doughnut",
  "data": {
    "labels": ["Success (${success_rate}%)", "Failure (${error_rate}%)"],
    "datasets": [{
      "data": [${success_count}, ${error_count}],
      "backgroundColor": ["#4B286D", "#00B7C3"]
    }]
  },
  "options": {
    "plugins": {
      "title": {
        "display": true,
        "text": "Backup Status Overview"
      },
      "legend": {
        "position": "bottom"
      }
    }
  }
}
EOF
)"

# === STORAGE PER DB ENGINE ===
engine_storage=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -N -e "
SELECT DB_engine, ROUND(SUM(CASE size_name
    WHEN 'B' THEN size/1024/1024/1024
    WHEN 'KB' THEN size/1024/1024
    WHEN 'MB' THEN size/1024
    WHEN 'GB' THEN size
    ELSE 0 END), 1) AS TotalGB
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY DB_engine;
")

# === TOP 5 AGGREGATED BACKUPS (Normalized to MB) ===
top_backups=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "
SELECT Server, DB_engine, CONCAT(ROUND(SUM(
  CASE size_name
    WHEN 'B' THEN size / 1024 / 1024
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
    WHEN 'B' THEN size / 1024 / 1024
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
table {
  width: 100%;
  border-collapse: collapse;
  margin-top: 20px;
  border: 1px solid #e0d6f0;
  border-radius: 8px;
  overflow: hidden;
  box-shadow: 0 0 8px rgba(0,0,0,0.05);
}
th {
  background-color: #4B286D;
  color: white;
  padding: 10px;
  text-align: left;
}
td {
  padding: 10px;
  border-bottom: 1px solid #eee;
}
tr:nth-child(even) { background-color: #f9f9f9; }
.chart-frame {
  border: 1px solid #e0d6f0;
  border-radius: 10px;
  padding: 10px;
  box-shadow: 0 0 8px rgba(0,0,0,0.05);
  background-color: #fff;
}
.bar-container {
  margin-bottom: 12px;
}
.bar-label {
  font-weight: bold;
  margin-bottom: 4px;
}
.bar {
  background-color: #e0d6f0;
  border-radius: 6px;
  overflow: hidden;
}
.bar-fill {
  background-color: #78BE20;
  color: white;
  padding: 8px;
  font-weight: bold;
}
</style></head><body><div class='container'>"

echo "<h1>Daily Backup Report - ${REPORT_DATE}</h1>"
echo "<div style='padding: 15px; background-color: #f7f3fb; border-left: 5px solid #4B286D; margin-bottom: 20px;'>"
echo "<p><strong>Executive Summary:</strong><br>"
echo "<span style='color: #008000;'>Status: HIGH SUCCESS (${success_rate}%)</span> | Total Failures: ${error_count} | Total Storage: ${total_storage} GB</p>"
echo "</div>"

echo "<table><tr><td class='chart-frame' style='width: 50%; text-align: center;'><img src='${DONUT_CHART_URL}' style='max-width: 100%;'></td>"
echo "<td class='chart-frame' style='width: 50%; vertical-align: top;'>"
echo "<h3 style='color: #4B286D; margin-bottom: 10px;'>Daily Storage Utilization (GB)</h3>"

# === EMBEDDED BAR CHART ===
max=0
declare -A engine_map
while IFS=$'\t' read -r engine gb; do
  engine_map["$engine"]=$gb
  gb_int=$(printf "%.0f" "$gb")
  (( gb_int > max )) && max=$gb_int
done <<< "${engine_storage}"

for engine in "${!engine_map[@]}"; do
  percent=$(awk "BEGIN {printf \"%.0f\", (${engine_map[$engine]} / $max) * 100}")
  echo "<div class='bar-container'><div class='bar-label'>${engine}</div>"
  echo "<div class='bar'><div class='bar-fill' style='width:${percent}%;'>${engine_map[$engine]} GB</div></div></div>"
done

echo "</td></tr></table>"

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

echo "Email sent to yvette.halili@telusinternational.com"
