CREATE OR REPLACE PACKAGE BODY loan_mod_batch_pkg AS
    
    PROCEDURE log_batch_progress(
        p_batch_id IN NUMBER,
        p_status IN VARCHAR2,
        p_message IN VARCHAR2
    ) IS
    BEGIN
        INSERT INTO batch_processing_log (
            log_id,
            batch_id,
            process_type,
            status,
            message,
            created_date
        ) VALUES (
            batch_log_seq.NEXTVAL,
            p_batch_id,
            'LOAN_MOD',
            p_status,
            p_message,
            SYSDATE
        );
        COMMIT;
    END log_batch_progress;
    
    PROCEDURE process_modification_batch(
        p_batch_id IN NUMBER,
        p_processing_date IN DATE DEFAULT SYSDATE
    ) IS
        v_loans t_loan_id_table;
        v_processed_count NUMBER := 0;
        v_failed_count NUMBER := 0;
        v_start_time TIMESTAMP;
    BEGIN
        v_start_time := SYSTIMESTAMP;
        
        -- Log batch start
        log_batch_progress(
            p_batch_id,
            'STARTED',
            'Starting modification batch processing'
        );
        
        -- Get loans pending modification
        SELECT loan_id
        BULK COLLECT INTO v_loans
        FROM loan_modification_history
        WHERE batch_id = p_batch_id
        AND status = 'PENDING'
        AND effective_date <= p_processing_date;
        
        -- Process modifications in batches
        FOR i IN 0 .. TRUNC((v_loans.COUNT - 1) / c_batch_size) LOOP
            BEGIN
                FORALL j IN (i * c_batch_size + 1) .. 
                           LEAST((i + 1) * c_batch_size, v_loans.COUNT)
                    UPDATE loan_modification_history
                    SET status = 'ACTIVE',
                        last_updated_date = SYSDATE,
                        last_updated_by = USER
                    WHERE loan_id = v_loans(j)
                    AND batch_id = p_batch_id
                    AND status = 'PENDING';
                
                v_processed_count := v_processed_count + SQL%ROWCOUNT;
                
                -- Update loan master status
                FORALL j IN (i * c_batch_size + 1) .. 
                           LEAST((i + 1) * c_batch_size, v_loans.COUNT)
                    UPDATE loan_master
                    SET modification_flag = 'Y',
                        modified_date = SYSDATE
                    WHERE loan_id = v_loans(j);
                
                COMMIT;
                
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
                    v_failed_count := v_failed_count + 1;
                    
                    -- Log error
                    investor_reporting_pkg.log_exception(
                        NULL,
                        v_loans(i * c_batch_size + 1),
                        'BATCH_MOD_ERROR',
                        'HIGH',
                        'Error processing modification batch: ' || SQLERRM
                    );
            END;
        END LOOP;
        
        -- Log batch completion
        log_batch_progress(
            p_batch_id,
            'COMPLETED',
            'Processed ' || v_processed_count || ' modifications, ' ||
            v_failed_count || ' failures. ' ||
            'Duration: ' || 
            EXTRACT(MINUTE FROM (SYSTIMESTAMP - v_start_time)) || ' minutes'
        );
        
        -- Handle failed modifications if any
        IF v_failed_count > 0 THEN
            handle_failed_modifications(p_batch_id);
        END IF;
        
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_batch_progress(
                p_batch_id,
                'FAILED',
                'Batch processing failed: ' || SQLERRM
            );
            RAISE;
    END process_modification_batch;
    
    PROCEDURE handle_failed_modifications(
        p_batch_id IN NUMBER,
        p_retry_count IN NUMBER DEFAULT 1
    ) IS
        v_failed_loans t_loan_id_table;
    BEGIN
        -- Get failed modifications
        SELECT loan_id
        BULK COLLECT INTO v_failed_loans
        FROM loan_modification_history
        WHERE batch_id = p_batch_id
        AND status = 'PENDING'
        AND effective_date <= SYSDATE;
        
        -- If retry limit not reached, attempt to process again
        IF p_retry_count < c_max_retries AND v_failed_loans.COUNT > 0 THEN
            -- Log retry attempt
            log_batch_progress(
                p_batch_id,
                'RETRY',
                'Attempting retry ' || p_retry_count || 
                ' for ' || v_failed_loans.COUNT || ' failed modifications'
            );
            
            -- Process failed modifications
            FOR i IN 1..v_failed_loans.COUNT LOOP
                BEGIN
                    loan_modification_pkg.process_loan_modification(
                        p_loan_id => v_failed_loans(i),
                        p_mod_type => 'DLQ_MOD',  -- Default type for retries
                        p_new_rate => NULL,       -- Will be fetched from history
                        p_new_term => NULL,       -- Will be fetched from history
                        p_forbearance_amt => NULL, -- Will be fetched from history
                        p_effective_date => SYSDATE,
                        p_batch_id => p_batch_id
                    );
                EXCEPTION
                    WHEN OTHERS THEN
                        -- Log individual failures
                        investor_reporting_pkg.log_exception(
                            NULL,
                            v_failed_loans(i),
                            'MOD_RETRY_ERROR',
                            'HIGH',
                            'Retry ' || p_retry_count || ' failed: ' || SQLERRM
                        );
                END;
            END LOOP;
            
            -- Recursive call for remaining failed modifications
            handle_failed_modifications(p_batch_id, p_retry_count + 1);
        ELSE
            -- Log final failure count
            log_batch_progress(
                p_batch_id,
                'RETRY_COMPLETE',
                v_failed_loans.COUNT || ' modifications remain failed after ' ||
                p_retry_count || ' retries'
            );
        END IF;
    END handle_failed_modifications;
    
    PROCEDURE cleanup_completed_modifications(
        p_days_old IN NUMBER DEFAULT 90
    ) IS
        v_deleted_count NUMBER := 0;
    BEGIN
        -- Archive old completed modifications
        INSERT INTO loan_modification_archive
        SELECT *
        FROM loan_modification_history
        WHERE status = 'COMPLETED'
        AND effective_date < SYSDATE - p_days_old;
        
        v_deleted_count := SQL%ROWCOUNT;
        
        -- Delete archived records
        DELETE FROM loan_modification_history
        WHERE status = 'COMPLETED'
        AND effective_date < SYSDATE - p_days_old;
        
        -- Log cleanup results
        log_batch_progress(
            NULL,
            'CLEANUP',
            'Archived ' || v_deleted_count || 
            ' completed modifications older than ' || p_days_old || ' days'
        );
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            investor_reporting_pkg.log_exception(
                NULL,
                NULL,
                'MOD_CLEANUP_ERROR',
                'MEDIUM',
                'Error during modification cleanup: ' || SQLERRM
            );
            RAISE;
    END cleanup_completed_modifications;
    
    FUNCTION get_batch_status(
        p_batch_id IN NUMBER
    ) RETURN VARCHAR2 IS
        v_total_count NUMBER;
        v_completed_count NUMBER;
        v_failed_count NUMBER;
        v_status VARCHAR2(100);
    BEGIN
        -- Get counts
        SELECT COUNT(*),
               COUNT(CASE WHEN status = 'COMPLETED' THEN 1 END),
               COUNT(CASE WHEN status = 'FAILED' THEN 1 END)
        INTO v_total_count, v_completed_count, v_failed_count
        FROM loan_modification_history
        WHERE batch_id = p_batch_id;
        
        -- Determine status
        IF v_total_count = 0 THEN
            v_status := 'BATCH_NOT_FOUND';
        ELSIF v_completed_count = v_total_count THEN
            v_status := 'COMPLETED';
        ELSIF v_failed_count = v_total_count THEN
            v_status := 'FAILED';
        ELSE
            v_status := 'IN_PROGRESS: ' || 
                       v_completed_count || '/' || v_total_count || 
                       ' completed, ' || v_failed_count || ' failed';
        END IF;
        
        RETURN v_status;
    END get_batch_status;
    
END loan_mod_batch_pkg;
/ 