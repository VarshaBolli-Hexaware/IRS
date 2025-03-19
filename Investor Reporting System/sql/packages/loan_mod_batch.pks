CREATE OR REPLACE PACKAGE loan_mod_batch_pkg AS
    -- Constants
    c_batch_size CONSTANT NUMBER := 1000;
    c_max_retries CONSTANT NUMBER := 3;
    
    -- Types
    TYPE t_loan_id_table IS TABLE OF VARCHAR2(20);
    
    -- Core procedures
    PROCEDURE process_modification_batch(
        p_batch_id IN NUMBER,
        p_processing_date IN DATE DEFAULT SYSDATE
    );
    
    PROCEDURE handle_failed_modifications(
        p_batch_id IN NUMBER,
        p_retry_count IN NUMBER DEFAULT 1
    );
    
    PROCEDURE cleanup_completed_modifications(
        p_days_old IN NUMBER DEFAULT 90
    );
    
    FUNCTION get_batch_status(
        p_batch_id IN NUMBER
    ) RETURN VARCHAR2;
END loan_mod_batch_pkg;
/