#!/bin/bash

# === CONFIGURATION ===
DB_USER="trtel.backup"
DB_PASS="Telus2017#"
DB_NAME="ti_db_inventory"
REPORT_DATE=$(date -d "yesterday" '+%Y-%m-%d')
DIR="backup"
mkdir -p "${DIR}"
emailFile="${DIR}/daily_backup_report.html"
LOG_FILE="${DIR}/debug.log"
: > "${LOG_FILE}"

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

# === CHART: DONUT ===
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

# === CHART: BAR (Storage per DB Engine in GB) ===
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

labels=""
values=""
colors=""
while IFS=$'\t' read -r engine total; do
    labels="${labels}\"${engine}\","
    values="${values}${total},"
    case "$engine" in
        MYSQL) colors="${colors}\"#00B7C3\"," ;;
        PGSQL) colors="${colors}\"#4B286D\"," ;;
        MSSQL) colors="${colors}\"#F4F4F4\"," ;;
        *) colors="${colors}\"#CCCCCC\"," ;;
    esac
done <<< "${engine_storage}"

labels="[${labels%,}]"
values="[${values%,}]"
colors="[${colors%,}]"

STACKED_CHART_URL="https://quickchart.io/chart?c=$(jq -sRr @uri <<< "
{
  \"type\": \"bar\",
  \"data\": {
    \"labels\": ${labels},
    \"datasets\": [{
      \"label\": \"GB\",
      \"data\": ${values},
      \"backgroundColor\": ${colors}
    }]
  },
  \"options\": {
    \"plugins\": {
      \"title\": {
        \"display\": true,
        \"text\": \"Daily Storage Utilization (GB)\"
      },
      \"legend\": {
        \"display\": false
      }
    },
    \"scales\": {
      \"y\": {
        \"beginAtZero\": true,
        \"title\": {
          \"display\": true,
          \"text\": \"GB\"
        }
      }
    }
  }
}
")"

# === TOP 5 AGGREGATED BACKUPS (in GB) ===
top_backups=$(mysql -u"${DB_USER}" -p"${DB_PASS}" -D"${DB_NAME}" -e "
SELECT Server, DB_engine, CONCAT(ROUND(SUM(
  CASE size_name
    WHEN 'B' THEN size / 1024 / 1024 / 1024
    WHEN 'KB' THEN size / 1024 / 1024
    WHEN 'MB' THEN size / 1024
    WHEN 'GB' THEN size
    ELSE 0
  END
), 2), ' GB') AS TotalSize
FROM daily_backup_report
WHERE backup_date = '${REPORT_DATE}'
GROUP BY Server, DB_engine
ORDER BY SUM(
  CASE size_name
    WHEN 'B' THEN size / 1024 / 1024 / 1024
    WHEN 'KB' THEN size / 1024 / 1024
    WHEN 'MB' THEN size / 1024
    WHEN 'GB' THEN size
    ELSE 0
  END
) DESC
LIMIT 5;
")

# === EMAIL HTML ===
{
echo "<!DOCTYPE html><html><head><meta charset='UTF-8'><style>
body {
  font-family: 'Segoe UI', 'Helvetica Neue', Arial, sans-serif;
  background-color: #f4f4f4;
  color: #333;
  padding: 20px;
}
.container {
  max-width: 800px;
  margin: auto;
  background-color: #fff;
  padding: 25px;
  border-radius: 12px;
  box-shadow: 0 0 12px rgba(75, 40, 109, 0.15);
  border: 1px solid #e0d6f0;
}
h1 {
  color: #4B286D;
  text-align: center;
  font-size: 26px;
  margin-bottom: 10px;
  border-bottom: 2px solid #4B286D;
  padding-bottom: 5px;
}
h2 {
  color: #4B286D;
  font-size: 20px;
  margin-top: 30px;
  border-bottom: 1px solid #ccc;
  padding-bottom: 5px;
}
.summary-box {
  background-color: #f7f3fb;
  border-left: 6px solid #4B286D;
  border-radius: 8px;
  padding: 15px;
  margin-bottom: 25px;
  font-size: 16px;
  box-shadow: inset 0 0 5px rgba(75, 40, 109, 0.05);
}
.chart-row {
  display: flex;
  justify-content: space-between;
  gap: 20px;
  margin-bottom: 30px;
}
.chart-row img {
  width: 100%;
  max-width: 360px;
  border: 1px solid #ddd;
  border-radius: 10px;
  box-shadow: 0 0 6px rgba(0, 0, 0, 0.05);
}
table {
  width: 100%;
  border-collapse: collapse;
  margin-top: 15px;
  border: 1px solid #e0d6f0;
  border-radius: 8px;
  overflow: hidden;
}
th {
  background-color: #4B286D;
  color: white;
  padding: 10px;
  text-align: left;
  border-bottom: 2px solid #ddd;
}
td {
  padding: 10px;
  border-bottom: 1px solid #eee;
}
tr:nth-child(even) {
  background-color: #f9f9f9;
}
.footer {
  text-align: center;
  margin-top: 40px;
  color: #4B286D;
  font-size: 14px;
  border-top: 1px solid #ccc;
  padding-top: 10px;
}
</style></head><body><div class='container'>"

echo "<h1>Daily Backup Report - ${REPORT_DATE}</h1>"
echo "<div class='summary-box'><strong>Executive Summary:</strong><br>"
echo "<span style='color: #008000;'>Status: HIGH SUCCESS (${success_rate}%)</span> | Total Failures: ${error_count} | Total Storage: ${total_storage} GB</div>"

echo "<div class='chart-row'><img src='${DONUT_CHART_URL}'><img src='${STACKED_CHART_URL}'></div>"

echo "<h2>Top 5 Largest Backups</h2><table><tr><th>Server</th><th>Database Engine</th><th>Size</th></tr>"
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

echo " Email sent to yvette.halili@telusinternational.com"
