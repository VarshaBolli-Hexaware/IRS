CREATE OR REPLACE PACKAGE BODY delinquency_processing_pkg AS
    
    FUNCTION get_days_past_due(
        p_loan_id IN VARCHAR2
    ) RETURN NUMBER IS
        v_days_past_due NUMBER;
        v_next_payment_date DATE;
    BEGIN
        -- Get the next payment date for the loan
        SELECT next_payment_date 
        INTO v_next_payment_date
        FROM loan_master
        WHERE loan_id = p_loan_id;
        
        -- Calculate days past due
        IF v_next_payment_date < TRUNC(SYSDATE) THEN
            v_days_past_due := TRUNC(SYSDATE) - v_next_payment_date;
        ELSE
            v_days_past_due := 0;
        END IF;
        
        RETURN v_days_past_due;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
        WHEN OTHERS THEN
            -- Log error and re-raise
            investor_reporting_pkg.log_exception(
                NULL,
                p_loan_id,
                'DELINQUENCY_CALCULATION_ERROR',
                'HIGH',
                'Error calculating days past due: ' || SQLERRM
            );
            RAISE;
    END get_days_past_due;
    
    PROCEDURE process_delinquencies IS
        CURSOR c_active_loans IS
            SELECT loan_id, 
                   next_payment_date,
                   current_balance,
                   status
            FROM loan_master
            WHERE status NOT IN ('LIQUIDATED', 'REO', 'PAID_OFF');
            
        v_days_past_due NUMBER;
        v_new_status VARCHAR2(20);
    BEGIN
        FOR r_loan IN c_active_loans LOOP
            -- Calculate days past due
            v_days_past_due := get_days_past_due(r_loan.loan_id);
            
            -- Determine new status based on delinquency days
            v_new_status := CASE
                WHEN v_days_past_due >= 90 THEN 'DEFAULT'
                WHEN v_days_past_due >= 30 THEN 'DELINQUENT'
                ELSE 'CURRENT'
            END;
            
            -- Update loan status if changed
            IF r_loan.status != v_new_status THEN
                UPDATE loan_master
                SET status = v_new_status,
                    delinquency_days = v_days_past_due,
                    modified_date = SYSDATE,
                    modified_by = USER
                WHERE loan_id = r_loan.loan_id;
                
                -- Log status change for significant delinquencies
                IF v_new_status IN ('DEFAULT', 'FORECLOSURE') THEN
                    investor_reporting_pkg.log_exception(
                        NULL,
                        r_loan.loan_id,
                        'DELINQUENCY_STATUS_CHANGE',
                        'HIGH',
                        'Loan status changed to ' || v_new_status || 
                        ' (' || v_days_past_due || ' days past due)' ||
                        ' Balance: $' || TO_CHAR(r_loan.current_balance, '999,999,999.99')
                    );
                END IF;
            END IF;
        END LOOP;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            investor_reporting_pkg.log_exception(
                NULL,
                NULL,
                'DELINQUENCY_PROCESSING_ERROR',
                'CRITICAL',
                'Error processing delinquencies: ' || SQLERRM
            );
            RAISE e_processing_error;
    END process_delinquencies;
    
END delinquency_processing_pkg;
/ 