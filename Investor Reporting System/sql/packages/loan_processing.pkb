CREATE OR REPLACE PACKAGE BODY loan_processing_pkg AS
   
    -- Private procedures and functions
    PROCEDURE log_exception (
        p_loan_id IN NUMBER,
        p_exception_type IN VARCHAR2,
        p_exception_desc IN VARCHAR2,
        p_severity IN VARCHAR2
    ) IS
    BEGIN
        INSERT INTO exception_log (
            exception_id, loan_id, exception_type, exception_desc, severity, status
        ) VALUES (
            exception_id_seq.NEXTVAL, p_loan_id, p_exception_type, p_exception_desc, p_severity, 'NEW'
        );
        COMMIT;
    END log_exception;
    
    FUNCTION validate_loan_parameters (
        p_original_amount IN NUMBER,
        p_interest_rate IN NUMBER,
        p_term_months IN NUMBER
    ) RETURN BOOLEAN IS
    BEGIN
        IF p_original_amount > c_max_loan_amount THEN
            RETURN FALSE;
        END IF;
        
        IF p_interest_rate < c_min_interest_rate OR p_interest_rate > c_max_interest_rate THEN
            RETURN FALSE;
        END IF;
        
        IF p_term_months NOT IN (180, 240, 360) THEN
            RETURN FALSE;
        END IF;
        
        RETURN TRUE;
    END validate_loan_parameters;
    
    -- Public procedure implementations
    PROCEDURE register_new_loan (
        p_fannie_loan_number IN VARCHAR2,
        p_original_amount IN NUMBER,
        p_interest_rate IN NUMBER,
        p_term_months IN NUMBER,
        p_origination_date IN DATE,
        p_loan_id OUT NUMBER
    ) IS
        v_valid BOOLEAN;
    BEGIN
        -- Validate loan parameters
        v_valid := validate_loan_parameters(p_original_amount, p_interest_rate, p_term_months);
        
        IF NOT v_valid THEN
            log_exception(
                NULL, 
                'LOAN_VALIDATION',
                'Invalid loan parameters: Amount=' || p_original_amount || 
                ', Rate=' || p_interest_rate || ', Term=' || p_term_months,
                'HIGH'
            );
            RAISE_APPLICATION_ERROR(-20001, 'Invalid loan parameters');
        END IF;
        
        -- Insert new loan
        SELECT loan_id_seq.NEXTVAL INTO p_loan_id FROM DUAL;
        
        INSERT INTO loan_master (
            loan_id,
            fannie_loan_number,
            origination_date,
            original_amount,
            current_balance,
            interest_rate,
            loan_term_months,
            remaining_term,
            next_payment_date,
            status
        ) VALUES (
            p_loan_id,
            p_fannie_loan_number,
            p_origination_date,
            p_original_amount,
            p_original_amount,
            p_interest_rate,
            p_term_months,
            p_term_months,
            ADD_MONTHS(p_origination_date, 1),
            'ACTIVE'
        );
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            log_exception(
                p_loan_id,
                'LOAN_REGISTRATION',
                'Error registering loan: ' || SQLERRM,
                'CRITICAL'
            );
            RAISE;
    END register_new_loan;
    
    PROCEDURE process_payment (
        p_loan_id IN NUMBER,
        p_payment_amount IN NUMBER,
        p_transaction_date IN DATE,
        p_transaction_id OUT NUMBER
    ) IS
        v_loan_details r_loan_details;
        v_monthly_payment NUMBER;
        v_principal_amount NUMBER;
        v_interest_amount NUMBER;
    BEGIN
        -- Get loan details
        v_loan_details := get_loan_details(p_loan_id);
        
        -- Calculate monthly P&I
        v_monthly_payment := p_payment_amount;
        v_interest_amount := ROUND(v_loan_details.current_balance * 
                                 (v_loan_details.interest_rate / 12), 2);
        v_principal_amount := v_monthly_payment - v_interest_amount;
        
        -- Validate payment
        IF p_payment_amount < v_interest_amount THEN
            log_exception(
                p_loan_id,
                'PAYMENT_VALIDATION',
                'Payment amount less than monthly interest due',
                'HIGH'
            );
            RAISE_APPLICATION_ERROR(-20002, 'Invalid payment amount');
        END IF;
        
        -- Record transaction
        SELECT transaction_id_seq.NEXTVAL INTO p_transaction_id FROM DUAL;
        
        INSERT INTO payment_transaction (
            transaction_id,
            loan_id,
            transaction_date,
            due_date,
            payment_amount,
            principal_amount,
            interest_amount,
            transaction_type,
            status
        ) VALUES (
            p_transaction_id,
            p_loan_id,
            p_transaction_date,
            v_loan_details.next_payment_date,
            p_payment_amount,
            v_principal_amount,
            v_interest_amount,
            'REGULAR_PAYMENT',
            'PROCESSED'
        );
        
        -- Update loan balance and payment dates
        UPDATE loan_master
        SET current_balance = current_balance - v_principal_amount,
            last_payment_date = p_transaction_date,
            next_payment_date = ADD_MONTHS(next_payment_date, 1),
            modified_date = SYSDATE
        WHERE loan_id = p_loan_id;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            log_exception(
                p_loan_id,
                'PAYMENT_PROCESSING',
                'Error processing payment: ' || SQLERRM,
                'CRITICAL'
            );
            RAISE;
    END process_payment;
    
    FUNCTION calculate_next_payment_date (
        p_loan_id IN NUMBER,
        p_current_date IN DATE DEFAULT SYSDATE
    ) RETURN DATE IS
        v_next_payment_date DATE;
    BEGIN
        SELECT next_payment_date
        INTO v_next_payment_date
        FROM loan_master
        WHERE loan_id = p_loan_id;
        
        RETURN v_next_payment_date;
    END calculate_next_payment_date;
    
    PROCEDURE update_loan_status (
        p_loan_id IN NUMBER,
        p_new_status IN VARCHAR2
    ) IS
        v_old_status loan_master.status%TYPE;
    BEGIN
        -- Get current status
        SELECT status
        INTO v_old_status
        FROM loan_master
        WHERE loan_id = p_loan_id;
        
        -- Validate status transition
        IF (v_old_status = 'PAID_OFF' AND p_new_status != 'PAID_OFF') OR
           (v_old_status = 'FORECLOSURE' AND p_new_status NOT IN ('FORECLOSURE', 'REO')) THEN
            log_exception(
                p_loan_id,
                'STATUS_UPDATE',
                'Invalid status transition from ' || v_old_status || ' to ' || p_new_status,
                'HIGH'
            );
            RAISE_APPLICATION_ERROR(-20003, 'Invalid status transition');
        END IF;
        
        -- Update status
        UPDATE loan_master
        SET status = p_new_status,
            modified_date = SYSDATE
        WHERE loan_id = p_loan_id;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            log_exception(
                p_loan_id,
                'STATUS_UPDATE',
                'Error updating loan status: ' || SQLERRM,
                'HIGH'
            );
            RAISE;
    END update_loan_status;
    
    FUNCTION get_loan_details (
        p_loan_id IN VARCHAR2
    ) RETURN r_loan_details IS
        v_loan_details r_loan_details;
    BEGIN
        SELECT loan_id,
               current_balance,
               interest_rate,
               next_payment_date,
               status
        INTO v_loan_details
        FROM loan_master
        WHERE loan_id = p_loan_id;
        
        RETURN v_loan_details;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            investor_reporting_pkg.log_exception(
                NULL,
                p_loan_id,
                'LOAN_DETAILS_ERROR',
                'HIGH',
                'Loan not found'
            );
            RAISE_APPLICATION_ERROR(-20001, 'Loan not found');
        WHEN OTHERS THEN
            investor_reporting_pkg.log_exception(
                NULL,
                p_loan_id,
                'LOAN_DETAILS_ERROR',
                'HIGH',
                'Error retrieving loan details: ' || SQLERRM
            );
            RAISE;
    END get_loan_details;
    
END loan_processing_pkg;
/ 