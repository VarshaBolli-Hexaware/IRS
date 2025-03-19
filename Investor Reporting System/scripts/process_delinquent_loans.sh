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
LOG_FILE="$LOG_DIR/delinquency_report_$TIMESTAMP.log"
REPORT_DATE=$(date +%Y-%m-%d)

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

log_message "Starting delinquent loan processing for $REPORT_DATE"

# Step 1: Update delinquency days for all loans
log_message "Updating delinquency days..."

SQL_UPDATE_DELINQUENCY="
DECLARE
    CURSOR c_loans IS
        SELECT loan_id, last_payment_date, next_payment_date
        FROM loan_master
        WHERE status NOT IN ('LIQUIDATED', 'REO');
    
    v_today DATE := TRUNC(SYSDATE);
    v_delinquency_days NUMBER;
BEGIN
    FOR r_loan IN c_loans LOOP
        -- Calculate delinquency days
        IF r_loan.next_payment_date < v_today THEN
            v_delinquency_days := v_today - r_loan.next_payment_date;
            
            -- Update loan status based on delinquency days
            UPDATE loan_master
            SET delinquency_days = v_delinquency_days,
                status = CASE 
                    WHEN v_delinquency_days > 90 THEN 'DEFAULT'
                    WHEN v_delinquency_days > 30 THEN 'DELINQUENT'
                    ELSE 'CURRENT'
                END,
                modified_date = SYSDATE,
                modified_by = USER
            WHERE loan_id = r_loan.loan_id;
        END IF;
    END LOOP;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20999, 'Error updating delinquency: ' || SQLERRM);
END;
/
"

execute_sql "$SQL_UPDATE_DELINQUENCY" "Failed to update delinquency status"

# Step 2: Generate delinquency report
log_message "Generating delinquency report..."

SQL_DELINQUENCY_REPORT="
SPOOL $REPORT_DIR/delinquency_report_$TIMESTAMP.txt

SELECT 
    p.pool_id,
    l.loan_id,
    l.current_balance,
    l.delinquency_days,
    l.status,
    TO_CHAR(l.last_payment_date, 'YYYY-MM-DD') as last_payment_date,
    TO_CHAR(l.next_payment_date, 'YYYY-MM-DD') as next_payment_date
FROM loan_master l
JOIN pool_loan_xref x ON l.loan_id = x.loan_id
JOIN pool_definition p ON x.pool_id = p.pool_id
WHERE l.status IN ('DELINQUENT', 'DEFAULT')
AND x.active_flag = 'Y'
ORDER BY p.pool_id, l.delinquency_days DESC;

SPOOL OFF
"

execute_sql "$SQL_DELINQUENCY_REPORT" "Failed to generate delinquency report"

# Step 3: Generate pool level delinquency summary
log_message "Generating pool delinquency summary..."

SQL_POOL_DELINQUENCY="
SPOOL $REPORT_DIR/pool_delinquency_summary_$TIMESTAMP.txt

SELECT 
    p.pool_id,
    p.pool_type,
    COUNT(l.loan_id) as total_loans,
    SUM(CASE WHEN l.status = 'CURRENT' THEN 1 ELSE 0 END) as current_loans,
    SUM(CASE WHEN l.status = 'DELINQUENT' THEN 1 ELSE 0 END) as delinquent_loans,
    SUM(CASE WHEN l.status = 'DEFAULT' THEN 1 ELSE 0 END) as default_loans,
    ROUND(SUM(CASE WHEN l.status IN ('DELINQUENT', 'DEFAULT') THEN l.current_balance ELSE 0 END) / 
          NULLIF(SUM(l.current_balance), 0) * 100, 2) as delinquent_balance_pct,
    ROUND(AVG(CASE WHEN l.status IN ('DELINQUENT', 'DEFAULT') THEN l.delinquency_days END), 0) as avg_days_delinquent
FROM pool_definition p
JOIN pool_loan_xref x ON p.pool_id = x.pool_id
JOIN loan_master l ON x.loan_id = l.loan_id
WHERE x.active_flag = 'Y'
GROUP BY p.pool_id, p.pool_type
HAVING SUM(CASE WHEN l.status IN ('DELINQUENT', 'DEFAULT') THEN 1 ELSE 0 END) > 0
ORDER BY delinquent_balance_pct DESC;

SPOOL OFF
"

execute_sql "$SQL_POOL_DELINQUENCY" "Failed to generate pool delinquency summary"

# Step 4: Generate alerts for severely delinquent loans
log_message "Generating severe delinquency alerts..."

SQL_SEVERE_ALERTS="
DECLARE
    CURSOR c_severe_delinquent IS
        SELECT 
            p.pool_id,
            l.loan_id,
            l.delinquency_days,
            l.current_balance
        FROM loan_master l
        JOIN pool_loan_xref x ON l.loan_id = x.loan_id
        JOIN pool_definition p ON x.pool_id = p.pool_id
        WHERE l.delinquency_days >= 60
        AND l.status = 'DEFAULT'
        AND x.active_flag = 'Y';
BEGIN
    FOR r_loan IN c_severe_delinquent LOOP
        -- Log exception for each severely delinquent loan
        INSERT INTO exception_log (
            exception_id,
            pool_id,
            loan_id,
            exception_type,
            severity,
            status,
            exception_desc,
            created_date
        ) VALUES (
            seq_exception_id.NEXTVAL,
            r_loan.pool_id,
            r_loan.loan_id,
            'SEVERE_DELINQUENCY',
            'HIGH',
            'OPEN',
            'Loan is ' || r_loan.delinquency_days || ' days delinquent with balance $' || 
            TO_CHAR(r_loan.current_balance, '999,999,999.99'),
            SYSDATE
        );
    END LOOP;
    COMMIT;
END;
/
"

execute_sql "$SQL_SEVERE_ALERTS" "Failed to generate severe delinquency alerts"

# Step 5: Cleanup old reports (keep last 90 days)
find "$REPORT_DIR" -name "*.txt" -type f -mtime +90 -delete
find "$LOG_DIR" -name "*.log" -type f -mtime +90 -delete

log_message "Delinquent loan processing completed successfully"
log_message "Reports generated in $REPORT_DIR"

# Email notification (uncomment and configure as needed)
# mail -s "SIR Delinquency Reports Generated" "team@example.com" << EOF
# Delinquency reports have been generated for $REPORT_DATE
# Location: $REPORT_DIR
# 
# Please review the reports for any severe delinquency cases.
# EOF

exit 0 