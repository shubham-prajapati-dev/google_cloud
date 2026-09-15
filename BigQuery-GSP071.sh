#!/bin/bash
set -Eeuo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# GSP071 - BigQuery: Qwik Start - Command Line
# Automates the lab tasks that have progress checks: Tasks 1, 3, 4 and 5.
# Task 2 (bq help query) is informational and is skipped because newer bq
# versions can return a non-zero status for the help command.
# Task 7 cleanup is skipped so the progress checks can verify the resources.

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  echo "ERROR: No active Google Cloud project."
  exit 1
fi

DATASET="babynames"
TABLE="names2010"
ZIP="names.zip"
FILE="yob2010.txt"

echo "============================================================"
echo " GSP071 - BigQuery: Qwik Start - Command Line"
echo "============================================================"
echo "Project: $PROJECT_ID"
echo

echo "[1/4] Examining Shakespeare table..."
bq show bigquery-public-data:samples.shakespeare

echo

echo "[2/4] Running raisin query..."
bq query --use_legacy_sql=false \
'SELECT
  word,
  SUM(word_count) AS count
FROM
  `bigquery-public-data`.samples.shakespeare
WHERE
  word LIKE "%raisin%"
GROUP BY
  word'

echo

echo "[2/4] Running huzzah query..."
bq query --use_legacy_sql=false \
'SELECT
  word
FROM
  `bigquery-public-data`.samples.shakespeare
WHERE
  word = "huzzah"'

echo

echo "[3/4] Creating babynames dataset..."
if bq show --format=none "$DATASET" >/dev/null 2>&1; then
  echo "  Dataset $DATASET already exists"
else
  bq mk "$DATASET"
  echo "  Dataset $DATASET created"
fi

echo
if [ ! -f "$ZIP" ]; then
  echo "Downloading baby names data..."
  wget -q http://www.ssa.gov/OACT/babynames/names.zip -O "$ZIP"
fi

if [ ! -f "$FILE" ]; then
  echo "Extracting baby names data..."
  unzip -o -q "$ZIP"
fi

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE was not found after extracting $ZIP."
  exit 1
fi

echo "Loading $FILE into $DATASET.$TABLE..."
if bq show --format=none "$DATASET.$TABLE" >/dev/null 2>&1; then
  echo "  Table $DATASET.$TABLE already exists"
else
  bq load "$DATASET.$TABLE" "$FILE" name:string,gender:string,count:integer
  echo "  Table $DATASET.$TABLE created and loaded"
fi

echo
bq show "$DATASET.$TABLE"
echo

echo "[4/4] Querying custom table..."
echo "Top 5 girls names:"
bq query --use_legacy_sql=false \
"SELECT name,count FROM \`$DATASET.$TABLE\` WHERE gender = 'F' ORDER BY count DESC LIMIT 5"

echo

echo "Top 5 unusual boys names:"
bq query --use_legacy_sql=false \
"SELECT name,count FROM \`$DATASET.$TABLE\` WHERE gender = 'M' ORDER BY count ASC LIMIT 5"

echo
echo "============================================================"
echo " GSP071 automation completed"
echo "============================================================"
echo "Dataset: $DATASET"
echo "Table:   $DATASET.$TABLE"
echo "Task 6 answers: Web UI, Command line tool, bq"
echo "Task 7 cleanup is intentionally NOT performed."
echo "============================================================"
