#!/bin/bash
set -Eeuo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# GSP787 - Derive Insights from BigQuery Data: Challenge Lab
# Automates Tasks 1-9 by executing the required BigQuery queries.
# Task 10 requires creating the Data Studio/Looker Studio report in the UI.

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  echo "ERROR: No active Google Cloud project."
  exit 1
fi

TABLE='`bigquery-public-data.covid19_open_data.covid19_open_data`'

echo "============================================================"
echo " GSP787 - Derive Insights from BigQuery Data"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo

echo "[Task 1] Total confirmed cases on 2020-06-15"
bq query --use_legacy_sql=false \
"SELECT SUM(cumulative_confirmed) AS total_cases_worldwide FROM $TABLE WHERE date = '2020-06-15'"

echo

echo "[Task 2] US states with more than 300 deaths on 2020-06-15"
bq query --use_legacy_sql=false \
"SELECT COUNT(subregion1_name) AS count_of_states FROM $TABLE WHERE country_name = 'United States of America' AND date = '2020-06-15' AND cumulative_deceased > 300 AND subregion1_name IS NOT NULL"

echo

echo "[Task 3] US states with more than 3000 confirmed cases on 2020-06-15"
bq query --use_legacy_sql=false \
"SELECT subregion1_name AS state, cumulative_confirmed AS total_confirmed_cases FROM $TABLE WHERE country_code = 'US' AND date = '2020-06-15' AND subregion1_name IS NOT NULL AND cumulative_confirmed > 3000 ORDER BY total_confirmed_cases DESC"

echo

echo "[Task 4] Italy case-fatality ratio for April 2020"
bq query --use_legacy_sql=false \
"SELECT SUM(cumulative_confirmed) AS total_confirmed_cases, SUM(cumulative_deceased) AS total_deaths, SAFE_DIVIDE(SUM(cumulative_deceased), SUM(cumulative_confirmed)) * 100 AS case_fatality_ratio FROM $TABLE WHERE country_name = 'Italy' AND date BETWEEN '2020-04-01' AND '2020-04-30'"

echo

echo "[Task 5] Date Italy crossed 16000 deaths"
bq query --use_legacy_sql=false \
"SELECT FORMAT_DATE('%Y-%m-%d', date) AS date FROM $TABLE WHERE country_name = 'Italy' AND cumulative_deceased > 16000 ORDER BY date ASC LIMIT 1"

echo

echo "[Task 6] India days with zero net new cases"
bq query --use_legacy_sql=false \
"WITH india_cases_by_date AS ( SELECT date, SUM(cumulative_confirmed) AS cases FROM $TABLE WHERE country_name = 'India' AND date BETWEEN '2020-02-24' AND '2020-03-15' GROUP BY date ), india_previous_day_comparison AS ( SELECT date, cases, LAG(cases) OVER(ORDER BY date) AS previous_day, cases - LAG(cases) OVER(ORDER BY date) AS net_new_cases FROM india_cases_by_date ) SELECT COUNTIF(net_new_cases = 0) AS zero_net_new_case_days FROM india_previous_day_comparison"

echo

echo "[Task 7] US dates with more than 20% daily increase"
bq query --use_legacy_sql=false \
"WITH us_cases_by_date AS ( SELECT date, SUM(cumulative_confirmed) AS cases FROM $TABLE WHERE country_name = 'United States of America' AND date BETWEEN '2020-03-22' AND '2020-04-20' GROUP BY date ), us_previous_day_comparison AS ( SELECT date, cases, LAG(cases) OVER(ORDER BY date) AS previous_day FROM us_cases_by_date ) SELECT date AS Date, cases AS Confirmed_Cases_On_Day, previous_day AS Confirmed_Cases_Previous_Day, SAFE_DIVIDE(cases - previous_day, previous_day) * 100 AS Percentage_Increase_In_Cases FROM us_previous_day_comparison WHERE previous_day IS NOT NULL AND SAFE_DIVIDE(cases - previous_day, previous_day) * 100 > 20 ORDER BY date ASC"

echo

echo "[Task 8] Top 20 country recovery rates on 2020-05-10"
bq query --use_legacy_sql=false \
"SELECT country_name AS country, SUM(cumulative_recovered) AS recovered_cases, SUM(cumulative_confirmed) AS confirmed_cases, SAFE_DIVIDE(SUM(cumulative_recovered), SUM(cumulative_confirmed)) * 100 AS recovery_rate FROM $TABLE WHERE date = '2020-05-10' AND country_name IS NOT NULL GROUP BY country_name HAVING SUM(cumulative_confirmed) > 50000 ORDER BY recovery_rate DESC LIMIT 20"

echo

echo "[Task 9] France CDGR"
bq query --use_legacy_sql=false \
"WITH france_cases AS ( SELECT date, SUM(cumulative_confirmed) AS total_cases FROM $TABLE WHERE country_name = 'France' AND date IN ('2020-01-24', '2020-06-15') GROUP BY date ), summary AS ( SELECT total_cases AS first_day_cases, LEAD(total_cases) OVER(ORDER BY date) AS last_day_cases, DATE_DIFF(LEAD(date) OVER(ORDER BY date), date, DAY) AS days_diff FROM france_cases ) SELECT first_day_cases, last_day_cases, days_diff, (POW(SAFE_DIVIDE(last_day_cases, first_day_cases), SAFE_DIVIDE(1, days_diff)) - 1) AS cdgr FROM summary WHERE last_day_cases IS NOT NULL LIMIT 1"

echo
 echo "============================================================"
echo " Tasks 1-9 completed"
echo "============================================================"
echo "Task 10 must be completed in Looker Studio/Data Studio."
echo "Use the BigQuery connector with a Custom Query for the US"
echo "and date range 2020-03-20 through 2020-04-25."
echo "============================================================"
