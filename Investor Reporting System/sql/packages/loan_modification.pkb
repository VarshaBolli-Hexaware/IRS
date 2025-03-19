CREATE OR REPLACE PACKAGE BODY loan_modification_pkg AS
    
    PROCEDURE log_modification_history(
        p_loan_id IN VARCHAR2,
        p_mod_type IN VARCHAR2,
        p_old_details IN loan_processing_pkg.r_loan_details,
        p_new_details IN loan_processing_pkg.r_loan_details,
        p_batch_id IN NUMBER
    ) IS
    BEGIN
        INSERT INTO loan_modification_history (
            modification_id,
            loan_id,
            mod_type,
            old_rate,
            new_rate,
            old_term,
            new_term,
            old_payment,
            new_payment,
            effective_date,
            batch_id,
            created_date,
            created_by
        ) VALUES (
            modification_seq.NEXTVAL,
            p_loan_id,
            p_mod_type,
            p_old_details.interest_rate,
            p_new_details.interest_rate,
            p_old_details.remaining_term,
            p_new_details.remaining_term,
            p_old_details.payment_amount,
            p_new_details.payment_amount,
            SYSDATE,
            p_batch_id,
            SYSDATE,
            USER
        );
    END log_modification_history;
    
    PROCEDURE process_loan_modification(
        p_loan_id IN VARCHAR2,
        p_mod_type IN VARCHAR2,
        p_new_rate IN NUMBER,
        p_new_term IN NUMBER,
        p_forbearance_amt IN NUMBER,
        p_effective_date IN DATE,
        p_batch_id IN NUMBER,
        p_processing_date IN DATE DEFAULT SYSDATE
    ) IS
        v_old_details loan_processing_pkg.r_loan_details;
        v_new_details loan_processing_pkg.r_loan_details;
        v_transaction_id NUMBER;
    BEGIN
        -- Get current loan details
        v_old_details := loan_processing_pkg.get_loan_details(p_loan_id);
        
        -- Create modification transaction
        INSERT INTO payment_transaction (
            transaction_id,
            loan_id,
            transaction_date,
            transaction_type,
            principal_amount,
            status,
            created_date
        ) VALUES (
            transaction_id_seq.NEXTVAL,
            p_loan_id,
            p_processing_date,
            p_mod_type,
            p_forbearance_amt,
            'PENDING',
            SYSDATE
        ) RETURNING transaction_id INTO v_transaction_id;
        
        -- Update loan terms
        UPDATE loan_master
        SET interest_rate = p_new_rate,
            remaining_term = p_new_term,
            modification_flag = 'Y',
            modified_date = SYSDATE
        WHERE loan_id = p_loan_id;
        
        -- Get updated loan details
        v_new_details := loan_processing_pkg.get_loan_details(p_loan_id);
        
        -- Log modification history
        log_modification_history(
            p_loan_id,
            p_mod_type,
            v_old_details,
            v_new_details,
            p_batch_id
        );
        
        -- Update transaction status
        UPDATE payment_transaction
        SET status = 'PROCESSED'
        WHERE transaction_id = v_transaction_id;
        
        -- Recalculate loan metrics
        loan_servicing_pkg.recalculate_loan_metrics(
            p_loan_id => p_loan_id,
            p_force_update => TRUE
        );
        
        -- Update pool metrics for affected pools
        FOR r_pool IN (
            SELECT pool_id 
            FROM pool_loan_xref 
            WHERE loan_id = p_loan_id
            AND active_flag = 'Y'
        ) LOOP
            pool_performance_pkg.generate_performance_report(
                p_pool_id => r_pool.pool_id,
                p_report_date => p_processing_date
            );
        END LOOP;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            investor_reporting_pkg.log_exception(
                NULL,
                p_loan_id,
                'LOAN_MODIFICATION',
                'HIGH',
                'Error processing loan modification: ' || SQLERRM
            );
            RAISE;
    END process_loan_modification;
    
    PROCEDURE cancel_modification(
        p_loan_id IN VARCHAR2,
        p_modification_id IN NUMBER,
        p_cancellation_date IN DATE,
        p_batch_id IN NUMBER
    ) IS
        v_mod_details r_modification_details;
        v_transaction_id NUMBER;
    BEGIN
        -- Get modification details
        SELECT *
        INTO v_mod_details
        FROM loan_modification_history
        WHERE modification_id = p_modification_id
        AND loan_id = p_loan_id;
        
        -- Create reversal transaction
        INSERT INTO payment_transaction (
            transaction_id,
            loan_id,
            transaction_date,
            transaction_type,
            status,
            created_date
        ) VALUES (
            transaction_id_seq.NEXTVAL,
            p_loan_id,
            p_cancellation_date,
            'MOD_CANCEL',
            'PENDING',
            SYSDATE
        ) RETURNING transaction_id INTO v_transaction_id;
        
        -- Revert loan terms
        UPDATE loan_master
        SET interest_rate = v_mod_details.old_rate,
            remaining_term = v_mod_details.old_term,
            modified_date = SYSDATE
        WHERE loan_id = p_loan_id;
        
        -- Update modification history
        UPDATE loan_modification_history
        SET cancellation_date = p_cancellation_date,
            status = 'CANCELLED',
            last_updated_date = SYSDATE
        WHERE modification_id = p_modification_id;
        
        -- Update transaction status
        UPDATE payment_transaction
        SET status = 'PROCESSED'
        WHERE transaction_id = v_transaction_id;
        
        -- Recalculate loan metrics
        loan_servicing_pkg.recalculate_loan_metrics(
            p_loan_id => p_loan_id,
            p_force_update => TRUE
        );
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            investor_reporting_pkg.log_exception(
                NULL,
                p_loan_id,
                'MOD_CANCELLATION',
                'HIGH',
                'Error cancelling modification: ' || SQLERRM
            );
            RAISE;
    END cancel_modification;
    
    FUNCTION get_active_modifications(
        p_loan_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR IS
        v_result SYS_REFCURSOR;
    BEGIN
        OPEN v_result FOR
            SELECT *
            FROM loan_modification_history
            WHERE loan_id = p_loan_id
            AND cancellation_date IS NULL
            ORDER BY effective_date DESC;
            
        RETURN v_result;
    END get_active_modifications;
    
    PROCEDURE update_modification_status(
        p_modification_id IN NUMBER,
        p_new_status IN VARCHAR2,
        p_batch_id IN NUMBER
    ) IS
        v_loan_id VARCHAR2(20);
    BEGIN
        SELECT loan_id
        INTO v_loan_id
        FROM loan_modification_history
        WHERE modification_id = p_modification_id;
        
        UPDATE loan_modification_history
        SET status = p_new_status,
            last_updated_date = SYSDATE,
            last_updated_by = USER
        WHERE modification_id = p_modification_id;
        
        -- Log status change
        investor_reporting_pkg.log_exception(
            NULL,
            v_loan_id,
            'MOD_STATUS_CHANGE',
            'LOW',
            'Modification status updated to ' || p_new_status
        );
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            investor_reporting_pkg.log_exception(
                NULL,
                v_loan_id,
                'MOD_STATUS_UPDATE',
                'HIGH',
                'Error updating modification status: ' || SQLERRM
            );
            RAISE;
    END update_modification_status;
    
END loan_modification_pkg;
/ 