CREATE OR REPLACE PACKAGE BODY investor_reporting_pkg AS
    -- Private procedures and functions
    PROCEDURE validate_input_parameters(
        p_pool_id IN VARCHAR2,
        p_date IN DATE
    ) IS
    BEGIN
        IF p_pool_id IS NULL OR NOT validate_pool_status(p_pool_id) THEN
            RAISE e_invalid_pool;
        END IF;
        
        IF p_date IS NULL OR p_date > SYSDATE THEN
            RAISE e_invalid_date;
        END IF;
    END validate_input_parameters;
    
    -- Implementation of public procedures and functions
    PROCEDURE process_remittance(
        p_pool_id IN VARCHAR2,
        p_remittance_date IN DATE,
        p_remittance_id OUT NUMBER
    ) IS
        v_total_scheduled_principal NUMBER := 0;
        v_total_unscheduled_principal NUMBER := 0;
        v_total_interest NUMBER := 0;
        v_pool_factor NUMBER;
        v_loan_count NUMBER := 0;
    BEGIN
        -- Validate input parameters
        validate_input_parameters(p_pool_id, p_remittance_date);
        
        -- Create new remittance record
        SELECT seq_remittance_id.NEXTVAL INTO p_remittance_id FROM DUAL;
        
        -- Process each loan in the pool
        FOR r_loan IN (
            SELECT l.loan_id, l.current_balance, l.interest_rate
            FROM loan_master l
            JOIN pool_loan_xref x ON l.loan_id = x.loan_id
            WHERE x.pool_id = p_pool_id
            AND x.active_flag = 'Y'
        ) LOOP
            -- Calculate loan payments
            DECLARE
                v_scheduled_payment NUMBER;
                v_interest_portion NUMBER;
                v_principal_portion NUMBER;
            BEGIN
                -- Your loan amortization calculation logic here
                -- This is a simplified example
                v_interest_portion := (r_loan.current_balance * r_loan.interest_rate) / 12;
                v_principal_portion := r_loan.current_balance * 0.002; -- Simplified
                
                -- Insert into loan payment history
                INSERT INTO loan_payment_history (
                    payment_id,
                    loan_id,
                    remittance_id,
                    payment_date,
                    scheduled_principal,
                    scheduled_interest,
                    beginning_balance,
                    ending_balance
                ) VALUES (
                    seq_payment_id.NEXTVAL,
                    r_loan.loan_id,
                    p_remittance_id,
                    p_remittance_date,
                    v_principal_portion,
                    v_interest_portion,
                    r_loan.current_balance,
                    r_loan.current_balance - v_principal_portion
                );
                
                -- Update totals
                v_total_scheduled_principal := v_total_scheduled_principal + v_principal_portion;
                v_total_interest := v_total_interest + v_interest_portion;
                v_loan_count := v_loan_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    log_exception(
                        p_pool_id,
                        r_loan.loan_id,
                        'PAYMENT_CALCULATION_ERROR',
                        'HIGH',
                        'Error calculating payment: ' || SQLERRM
                    );
            END;
        END LOOP;
        
        -- Calculate new pool factor
        SELECT current_amount INTO v_pool_factor
        FROM pool_definition
        WHERE pool_id = p_pool_id;
        
        v_pool_factor := (v_pool_factor - v_total_scheduled_principal - v_total_unscheduled_principal) /
                        v_pool_factor;
        
        -- Insert remittance record
        INSERT INTO monthly_remittance (
            remittance_id,
            pool_id,
            reporting_period,
            due_date,
            total_scheduled_principal,
            total_unscheduled_principal,
            total_interest,
            pool_factor_reported,
            status
        ) VALUES (
            p_remittance_id,
            p_pool_id,
            TRUNC(p_remittance_date, 'MM'),
            LAST_DAY(p_remittance_date),
            v_total_scheduled_principal,
            v_total_unscheduled_principal,
            v_total_interest,
            v_pool_factor,
            'SUBMITTED'
        );
        
        -- Update pool factor
        update_pool_factor(p_pool_id, v_pool_factor);
        
        COMMIT;
    EXCEPTION
        WHEN e_invalid_pool THEN
            RAISE_APPLICATION_ERROR(-20001, 'Invalid pool ID: ' || p_pool_id);
        WHEN e_invalid_date THEN
            RAISE_APPLICATION_ERROR(-20002, 'Invalid remittance date');
        WHEN OTHERS THEN
            ROLLBACK;
            log_exception(
                p_pool_id,
                NULL,
                'REMITTANCE_PROCESSING_ERROR',
                'CRITICAL',
                'Error processing remittance: ' || SQLERRM
            );
            RAISE e_processing_error;
    END process_remittance;
    
    PROCEDURE generate_monthly_report(
        p_pool_id IN VARCHAR2,
        p_report_date IN DATE
    ) IS
        v_report_data CLOB;
        
        -- Cursor for loan details
        CURSOR c_loan_details IS
            SELECT l.loan_id,
                   l.current_balance,
                   l.status,
                   l.delinquency_days
            FROM loan_master l
            JOIN pool_loan_xref x ON l.loan_id = x.loan_id
            WHERE x.pool_id = p_pool_id
            AND x.active_flag = 'Y';
    BEGIN
        -- Validate input parameters
        validate_input_parameters(p_pool_id, p_report_date);
        
        -- Generate report header
        v_report_data := 'Monthly Investor Report' || CHR(10) ||
                        'Pool ID: ' || p_pool_id || CHR(10) ||
                        'Report Date: ' || TO_CHAR(p_report_date, 'YYYY-MM-DD') || CHR(10);
        
        -- Add pool summary
        FOR r_pool IN (
            SELECT *
            FROM pool_definition
            WHERE pool_id = p_pool_id
        ) LOOP
            v_report_data := v_report_data || CHR(10) ||
                            'Pool Summary:' || CHR(10) ||
                            'Current Amount: ' || TO_CHAR(r_pool.current_amount, '999,999,999.99') || CHR(10) ||
                            'Pool Factor: ' || TO_CHAR(r_pool.pool_factor, '0.99999999') || CHR(10) ||
                            'Weighted Rate: ' || TO_CHAR(r_pool.weighted_rate, '0.9999');
        END LOOP;
        
        -- Add loan details
        v_report_data := v_report_data || CHR(10) || CHR(10) ||
                        'Loan Performance Summary:' || CHR(10);
                        
        FOR r_loan IN c_loan_details LOOP
            v_report_data := v_report_data ||
                            'Loan: ' || r_loan.loan_id ||
                            ', Balance: ' || TO_CHAR(r_loan.current_balance, '999,999,999.99') ||
                            ', Status: ' || r_loan.status ||
                            CASE WHEN r_loan.delinquency_days > 0
                                 THEN ', Days Delinquent: ' || r_loan.delinquency_days
                                 ELSE ''
                            END || CHR(10);
        END LOOP;
        
        -- Store report in monthly_reports table
        INSERT INTO monthly_reports (
            report_id,
            pool_id,
            report_date,
            report_content,
            created_date
        ) VALUES (
            seq_report_id.NEXTVAL,
            p_pool_id,
            p_report_date,
            v_report_data,
            SYSDATE
        );
        
        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            log_exception(
                p_pool_id,
                NULL,
                'REPORT_GENERATION_ERROR',
                'HIGH',
                'Error generating monthly report: ' || SQLERRM
            );
            RAISE e_processing_error;
    END generate_monthly_report;
    
    PROCEDURE calculate_pool_statistics(
        p_pool_id IN VARCHAR2,
        p_calculation_date IN DATE
    ) IS
        v_total_balance NUMBER := 0;
        v_weighted_rate NUMBER := 0;
    BEGIN
        -- Calculate pool statistics
        SELECT SUM(l.current_balance),
               SUM(l.current_balance * l.interest_rate) / SUM(l.current_balance)
        INTO v_total_balance, v_weighted_rate
        FROM loan_master l
        JOIN pool_loan_xref x ON l.loan_id = x.loan_id
        WHERE x.pool_id = p_pool_id
        AND x.active_flag = 'Y';
        
        -- Update pool definition
        UPDATE pool_definition
        SET current_amount = v_total_balance,
            weighted_rate = v_weighted_rate,
            modified_date = SYSDATE,
            modified_by = USER
        WHERE pool_id = p_pool_id;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_exception(
                p_pool_id,
                NULL,
                'STATISTICS_CALCULATION_ERROR',
                'HIGH',
                'Error calculating pool statistics: ' || SQLERRM
            );
            RAISE e_processing_error;
    END calculate_pool_statistics;
    
    FUNCTION validate_pool_status(
        p_pool_id IN VARCHAR2
    ) RETURN BOOLEAN IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT status INTO v_status
        FROM pool_definition
        WHERE pool_id = p_pool_id;
        
        RETURN v_status = 'ACTIVE';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN FALSE;
    END validate_pool_status;
    
    PROCEDURE log_exception(
        p_pool_id IN VARCHAR2,
        p_loan_id IN VARCHAR2,
        p_exception_type IN VARCHAR2,
        p_severity IN VARCHAR2,
        p_description IN VARCHAR2
    ) IS
    BEGIN
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
            p_pool_id,
            p_loan_id,
            p_exception_type,
            p_severity,
            'OPEN',
            p_description,
            SYSDATE
        );
        COMMIT;
    END log_exception;
    
    PROCEDURE update_pool_factor(
        p_pool_id IN VARCHAR2,
        p_new_factor IN NUMBER
    ) IS
    BEGIN
        UPDATE pool_definition
        SET pool_factor = p_new_factor,
            modified_date = SYSDATE,
            modified_by = USER
        WHERE pool_id = p_pool_id;
    END update_pool_factor;
    
    PROCEDURE process_loan_payoff(
        p_loan_id IN VARCHAR2,
        p_payoff_date IN DATE,
        p_payoff_amount IN NUMBER
    ) IS
        v_pool_id VARCHAR2(12);
    BEGIN
        -- Get pool ID
        SELECT pool_id INTO v_pool_id
        FROM pool_loan_xref
        WHERE loan_id = p_loan_id
        AND active_flag = 'Y';
        
        -- Update loan status
        UPDATE loan_master
        SET status = 'LIQUIDATED',
            current_balance = 0,
            modified_date = SYSDATE,
            modified_by = USER
        WHERE loan_id = p_loan_id;
        
        -- Update pool loan cross reference
        UPDATE pool_loan_xref
        SET active_flag = 'N',
            termination_date = p_payoff_date,
            modified_date = SYSDATE,
            modified_by = USER
        WHERE loan_id = p_loan_id
        AND pool_id = v_pool_id;
        
        -- Recalculate pool statistics
        calculate_pool_statistics(v_pool_id, p_payoff_date);
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_exception(
                v_pool_id,
                p_loan_id,
                'LOAN_PAYOFF_ERROR',
                'HIGH',
                'Error processing loan payoff: ' || SQLERRM
            );
            RAISE e_processing_error;
    END process_loan_payoff;
    
END investor_reporting_pkg;
/ 