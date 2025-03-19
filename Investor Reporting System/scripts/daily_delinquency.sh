#!/bin/bash

# Configuration
ORACLE_USER="sir_user"
ORACLE_PWD="$ORACLE_PASSWORD"  # Should be set in environment
ORACLE_SID="SIRDB"
LOG_DIR="/var/log/sir"
REPORT_DIR="/var/reports/sir/delinquency"

# Ensure required directories exist
mkdir -p "$LOG_DIR"
mkdir -p "$REPORT_DIR"

# Set up logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/delinquency_process_$TIMESTAMP.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

handle_error() {
    log_message "ERROR: $1"
    exit 1
}

# Validate environment
if [ -z "$ORACLE_PASSWORD" ]; then
    handle_error "ORACLE_PASSWORD environment variable not set"
fi

# Function to execute SQL and handle errors
execute_sql() {
    local sql_command="$1"
    local error_msg="$2"
    
    echo "$sql_command" | sqlplus -S "$ORACLE_USER/$ORACLE_PWD@$ORACLE_SID" || handle_error "$error_msg"
}

log_message "Starting daily delinquency processing"

# Step 1: Process delinquencies
log_message "Processing loan delinquencies..."

SQL_PROCESS_DELINQUENCIES="
BEGIN
    delinquency_processing_pkg.process_delinquencies;
END;
/
"

execute_sql "$SQL_PROCESS_DELINQUENCIES" "Failed to process delinquencies"

# Step 2: Generate delinquency report
log_message "Generating delinquency report..."

SQL_DELINQUENCY_REPORT="
SPOOL $REPORT_DIR/delinquency_report_$TIMESTAMP.txt

SELECT l.loan_id,
       l.fannie_loan_number,
       l.status,
       l.current_balance,
       delinquency_processing_pkg.get_days_past_due(l.loan_id) as days_past_due,
       TO_CHAR(l.next_payment_date, 'YYYY-MM-DD') as next_payment_due,
       TO_CHAR(l.last_payment_date, 'YYYY-MM-DD') as last_payment_date,
       p.pool_id
FROM loan_master l
JOIN pool_loan_xref x ON l.loan_id = x.loan_id
JOIN pool_definition p ON x.pool_id = p.pool_id
WHERE l.status IN ('DEFAULT', 'FORECLOSURE')
AND x.active_flag = 'Y'
ORDER BY days_past_due DESC;

SPOOL OFF
"

execute_sql "$SQL_DELINQUENCY_REPORT" "Failed to generate delinquency report"

# Step 3: Generate summary statistics
log_message "Generating summary statistics..."

SQL_SUMMARY_STATS="
SPOOL $REPORT_DIR/delinquency_summary_$TIMESTAMP.txt

SELECT 
    COUNT(CASE WHEN l.status = 'ACTIVE' THEN 1 END) as active_loans,
    COUNT(CASE WHEN l.status = 'DEFAULT' THEN 1 END) as defaulted_loans,
    COUNT(CASE WHEN l.status = 'FORECLOSURE' THEN 1 END) as foreclosure_loans,
    COUNT(CASE WHEN l.status = 'REO' THEN 1 END) as reo_loans,
    ROUND(AVG(CASE WHEN l.status IN ('DEFAULT', 'FORECLOSURE') 
              THEN delinquency_processing_pkg.get_days_past_due(l.loan_id) 
              END), 2) as avg_days_past_due,
    ROUND(SUM(CASE WHEN l.status IN ('DEFAULT', 'FORECLOSURE') 
              THEN l.current_balance END) / 
          NULLIF(SUM(l.current_balance), 0) * 100, 2) as delinquent_balance_pct
FROM loan_master l
WHERE l.status != 'PAID_OFF';

SPOOL OFF
"

execute_sql "$SQL_SUMMARY_STATS" "Failed to generate summary statistics"

# Step 4: Check for critical delinquencies
log_message "Checking for critical delinquencies..."

SQL_CHECK_CRITICAL="
SPOOL $REPORT_DIR/critical_delinquencies_$TIMESTAMP.txt

SELECT l.loan_id,
       l.fannie_loan_number,
       l.status,
       l.current_balance,
       delinquency_processing_pkg.get_days_past_due(l.loan_id) as days_past_due,
       p.pool_id,
       p.pool_factor
FROM loan_master l
JOIN pool_loan_xref x ON l.loan_id = x.loan_id
JOIN pool_definition p ON x.pool_id = p.pool_id
WHERE l.status IN ('DEFAULT', 'FORECLOSURE')
AND delinquency_processing_pkg.get_days_past_due(l.loan_id) >= 180
AND l.current_balance > 1000000
ORDER BY l.current_balance DESC;

SPOOL OFF
"

execute_sql "$SQL_CHECK_CRITICAL" "Failed to check critical delinquencies"

# Step 5: Cleanup old reports (keep last 30 days)
find "$REPORT_DIR" -name "*.txt" -type f -mtime +30 -delete

log_message "Daily delinquency processing completed successfully"
log_message "Reports generated in $REPORT_DIR"

# Email notification (uncomment and configure as needed)
# mail -s "SIR Daily Delinquency Report" "team@example.com" << EOF
# Daily delinquency processing has completed.
# Location: $REPORT_DIR
# 
# Please review the critical delinquencies report for high-balance loans.
# EOF

exit 0 