#!/bin/bash

# Configuration
ORACLE_USER="sir_user"
ORACLE_PWD="$ORACLE_PASSWORD"  # Should be set in environment
ORACLE_SID="SIRDB"
LOG_DIR="/var/log/sir"
REPORT_DIR="/var/reports/sir/payoffs"
PAYOFF_FILE="$1"  # Input file containing payoff information

# Ensure required directories exist
mkdir -p "$LOG_DIR"
mkdir -p "$REPORT_DIR"

# Set up logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/payoff_processing_$TIMESTAMP.log"
REPORT_DATE=$(date +%Y-%m-%d)

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

handle_error() {
    log_message "ERROR: $1"
    exit 1
}

# Validate environment and inputs
if [ -z "$ORACLE_PASSWORD" ]; then
    handle_error "ORACLE_PASSWORD environment variable not set"
fi

if [ -z "$PAYOFF_FILE" ]; then
    handle_error "Usage: $0 <payoff_file>"
fi

if [ ! -f "$PAYOFF_FILE" ]; then
    handle_error "Payoff file not found: $PAYOFF_FILE"
fi

# Function to execute SQL and handle errors
execute_sql() {
    local sql_command="$1"
    local error_msg="$2"
    
    echo "$sql_command" | sqlplus -S "$ORACLE_USER/$ORACLE_PWD@$ORACLE_SID" || handle_error "$error_msg"
}

log_message "Starting payoff processing for $REPORT_DATE"
log_message "Processing payoff file: $PAYOFF_FILE"

# Step 1: Load payoff data into temporary table
log_message "Loading payoff data..."

SQL_CREATE_TEMP="
CREATE GLOBAL TEMPORARY TABLE temp_payoffs (
    loan_id VARCHAR2(12),
    payoff_date DATE,
    payoff_amount NUMBER(15,2),
    payoff_type VARCHAR2(20)
) ON COMMIT PRESERVE ROWS;

TRUNCATE TABLE temp_payoffs;
"

execute_sql "$SQL_CREATE_TEMP" "Failed to create temporary table"

# Load data from CSV file (assuming format: loan_id,payoff_date,payoff_amount,payoff_type)
while IFS=, read -r loan_id payoff_date payoff_amount payoff_type; do
    SQL_LOAD_PAYOFF="
    INSERT INTO temp_payoffs (loan_id, payoff_date, payoff_amount, payoff_type)
    VALUES ('$loan_id', TO_DATE('$payoff_date', 'YYYY-MM-DD'), $payoff_amount, '$payoff_type');
    "
    execute_sql "$SQL_LOAD_PAYOFF" "Failed to load payoff data for loan $loan_id"
done < "$PAYOFF_FILE"

# Step 2: Process payoffs
log_message "Processing payoffs..."

SQL_PROCESS_PAYOFFS="
DECLARE
    CURSOR c_payoffs IS
        SELECT t.*, l.current_balance, x.pool_id
        FROM temp_payoffs t
        JOIN loan_master l ON t.loan_id = l.loan_id
        JOIN pool_loan_xref x ON l.loan_id = x.loan_id
        WHERE x.active_flag = 'Y';
        
    v_exception_msg VARCHAR2(4000);
BEGIN
    FOR r_payoff IN c_payoffs LOOP
        BEGIN
            -- Validate payoff amount
            IF ABS(r_payoff.payoff_amount - r_payoff.current_balance) / 
               NULLIF(r_payoff.current_balance, 0) > 0.001 THEN
                -- Log warning for significant difference
                INSERT INTO exception_log (
                    exception_id, pool_id, loan_id, exception_type, severity, 
                    status, exception_desc, created_date
                ) VALUES (
                    seq_exception_id.NEXTVAL,
                    r_payoff.pool_id,
                    r_payoff.loan_id,
                    'PAYOFF_AMOUNT_MISMATCH',
                    'MEDIUM',
                    'OPEN',
                    'Payoff amount differs from current balance by more than 0.1%: ' ||
                    'Payoff=' || TO_CHAR(r_payoff.payoff_amount, '999,999,999.99') ||
                    ', Balance=' || TO_CHAR(r_payoff.current_balance, '999,999,999.99'),
                    SYSDATE
                );
            END IF;
            
            -- Process the payoff
            investor_reporting_pkg.process_loan_payoff(
                r_payoff.loan_id,
                r_payoff.payoff_date,
                r_payoff.payoff_amount
            );
            
        EXCEPTION
            WHEN OTHERS THEN
                v_exception_msg := SQLERRM;
                -- Log error
                INSERT INTO exception_log (
                    exception_id, pool_id, loan_id, exception_type, severity, 
                    status, exception_desc, created_date
                ) VALUES (
                    seq_exception_id.NEXTVAL,
                    r_payoff.pool_id,
                    r_payoff.loan_id,
                    'PAYOFF_PROCESSING_ERROR',
                    'HIGH',
                    'OPEN',
                    'Error processing payoff: ' || v_exception_msg,
                    SYSDATE
                );
        END;
    END LOOP;
    COMMIT;
END;
/
"

execute_sql "$SQL_PROCESS_PAYOFFS" "Failed to process payoffs"

# Step 3: Generate payoff report
log_message "Generating payoff report..."

SQL_PAYOFF_REPORT="
SPOOL $REPORT_DIR/payoff_report_$TIMESTAMP.txt

SELECT 
    p.pool_id,
    l.loan_id,
    t.payoff_type,
    l.current_balance as original_balance,
    t.payoff_amount,
    t.payoff_date,
    CASE 
        WHEN ABS(t.payoff_amount - l.current_balance) / NULLIF(l.current_balance, 0) > 0.001 
        THEN 'WARNING: Amount mismatch'
        ELSE 'OK'
    END as status
FROM temp_payoffs t
JOIN loan_master l ON t.loan_id = l.loan_id
JOIN pool_loan_xref x ON l.loan_id = x.loan_id
JOIN pool_definition p ON x.pool_id = p.pool_id
WHERE x.active_flag = 'Y'
ORDER BY p.pool_id, t.payoff_date;

SPOOL OFF
"

execute_sql "$SQL_PAYOFF_REPORT" "Failed to generate payoff report"

# Step 4: Generate pool impact report
log_message "Generating pool impact report..."

SQL_POOL_IMPACT="
SPOOL $REPORT_DIR/pool_impact_report_$TIMESTAMP.txt

SELECT 
    p.pool_id,
    p.pool_type,
    COUNT(DISTINCT t.loan_id) as payoff_count,
    SUM(t.payoff_amount) as total_payoff_amount,
    ROUND(SUM(t.payoff_amount) / NULLIF(p.current_amount, 0) * 100, 2) as pct_of_pool
FROM pool_definition p
JOIN pool_loan_xref x ON p.pool_id = x.pool_id
JOIN loan_master l ON x.loan_id = l.loan_id
JOIN temp_payoffs t ON l.loan_id = t.loan_id
WHERE x.active_flag = 'Y'
GROUP BY p.pool_id, p.pool_type, p.current_amount
ORDER BY pct_of_pool DESC;

SPOOL OFF
"

execute_sql "$SQL_POOL_IMPACT" "Failed to generate pool impact report"

# Step 5: Cleanup
log_message "Cleaning up..."

SQL_CLEANUP="
DROP TABLE temp_payoffs;
"

execute_sql "$SQL_CLEANUP" "Failed to cleanup temporary tables"

# Step 6: Cleanup old reports (keep last 90 days)
find "$REPORT_DIR" -name "*.txt" -type f -mtime +90 -delete
find "$LOG_DIR" -name "*.log" -type f -mtime +90 -delete

log_message "Payoff processing completed successfully"
log_message "Reports generated in $REPORT_DIR"

# Email notification (uncomment and configure as needed)
# mail -s "SIR Payoff Processing Complete" "team@example.com" << EOF
# Payoff processing has been completed for $REPORT_DATE
# Location: $REPORT_DIR
# 
# Please review the reports for any warnings or exceptions.
# EOF

exit 0 