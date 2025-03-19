#!/bin/bash

# Configuration
ORACLE_USER="sir_user"
ORACLE_PWD="$ORACLE_PASSWORD"  # Should be set in environment
ORACLE_SID="SIRDB"
LOG_DIR="/var/log/sir"
REPORT_DIR="/var/reports/sir"

# Ensure required directories exist
mkdir -p "$LOG_DIR"
mkdir -p "$REPORT_DIR"

# Set up logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/monthly_report_$TIMESTAMP.log"
REPORT_DATE=$(date -d "last month" +%Y-%m-01)  # First day of previous month

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

log_message "Starting monthly reporting process for $REPORT_DATE"

# Step 1: Process all pools
log_message "Processing all active pools..."

SQL_PROCESS_POOLS="
DECLARE
    CURSOR c_pools IS
        SELECT pool_id 
        FROM pool_definition 
        WHERE pool_factor > 0;
    
    v_remittance_id NUMBER;
BEGIN
    FOR r_pool IN c_pools LOOP
        -- Process remittance
        investor_reporting_pkg.process_remittance(
            p_pool_id => r_pool.pool_id,
            p_remittance_date => TO_DATE('$REPORT_DATE', 'YYYY-MM-DD'),
            p_remittance_id => v_remittance_id
        );
        
        -- Generate monthly report
        investor_reporting_pkg.generate_monthly_report(
            p_pool_id => r_pool.pool_id,
            p_report_date => TO_DATE('$REPORT_DATE', 'YYYY-MM-DD')
        );
        
        COMMIT;
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20999, 'Error processing pools: ' || SQLERRM);
END;
/
"

execute_sql "$SQL_PROCESS_POOLS" "Failed to process pools"

# Step 2: Generate exception report
log_message "Generating exception report..."

SQL_EXCEPTION_REPORT="
SPOOL $REPORT_DIR/exception_report_$TIMESTAMP.txt

SELECT e.pool_id,
       e.exception_type,
       e.severity,
       e.status,
       e.exception_desc,
       TO_CHAR(e.created_date, 'YYYY-MM-DD HH24:MI:SS') as created_date
FROM exception_log e
WHERE e.created_date >= TO_DATE('$REPORT_DATE', 'YYYY-MM-DD')
AND e.severity IN ('HIGH', 'CRITICAL')
ORDER BY e.severity, e.created_date;

SPOOL OFF
"

execute_sql "$SQL_EXCEPTION_REPORT" "Failed to generate exception report"

# Step 3: Generate pool summary report
log_message "Generating pool summary report..."

SQL_POOL_SUMMARY="
SPOOL $REPORT_DIR/pool_summary_$TIMESTAMP.txt

SELECT p.pool_id,
       p.pool_type,
       p.current_amount,
       p.pool_factor,
       p.weighted_rate,
       COUNT(l.loan_id) as active_loans,
       SUM(CASE WHEN l.status = 'DEFAULT' THEN 1 ELSE 0 END) as delinquent_loans,
       SUM(CASE WHEN l.status = 'FORECLOSURE' THEN 1 ELSE 0 END) as foreclosure_loans
FROM pool_definition p
LEFT JOIN pool_loan_xref x ON p.pool_id = x.pool_id
LEFT JOIN loan_master l ON x.loan_id = l.loan_id
WHERE x.active_flag = 'Y'
GROUP BY p.pool_id, p.pool_type, p.current_amount, p.pool_factor, p.weighted_rate
ORDER BY p.pool_id;

SPOOL OFF
"

execute_sql "$SQL_POOL_SUMMARY" "Failed to generate pool summary report"

# Step 4: Cleanup old reports (keep last 12 months)
find "$REPORT_DIR" -name "*.txt" -type f -mtime +365 -delete
find "$LOG_DIR" -name "*.log" -type f -mtime +365 -delete

log_message "Monthly reporting process completed successfully"
log_message "Reports generated in $REPORT_DIR"

# Email notification (uncomment and configure as needed)
# mail -s "SIR Monthly Reports Generated" "team@example.com" << EOF
# Monthly reports have been generated for $REPORT_DATE
# Location: $REPORT_DIR
# 
# Please review the attached exception report for any critical issues.
# EOF

exit 0 