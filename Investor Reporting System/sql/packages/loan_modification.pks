CREATE OR REPLACE PACKAGE loan_modification_pkg AS
    -- Constants
    c_mod_type_delinquency CONSTANT VARCHAR2(10) := 'DLQ_MOD';
    c_mod_type_bankruptcy CONSTANT VARCHAR2(10) := 'BK_MOD';
    c_mod_type_disaster CONSTANT VARCHAR2(10) := 'DIS_MOD';
    
    -- Types
    TYPE r_modification_details IS RECORD (
        modification_id NUMBER,
        loan_id VARCHAR2(20),
        mod_type VARCHAR2(10),
        old_rate NUMBER,
        new_rate NUMBER,
        old_term NUMBER,
        new_term NUMBER,
        old_payment NUMBER,
        new_payment NUMBER,
        principal_forbearance NUMBER,
        effective_date DATE,
        cancellation_date DATE,
        status VARCHAR2(15)
    );
    
    -- Core procedures
    PROCEDURE process_loan_modification(
        p_loan_id IN VARCHAR2,
        p_mod_type IN VARCHAR2,
        p_new_rate IN NUMBER,
        p_new_term IN NUMBER,
        p_forbearance_amt IN NUMBER,
        p_effective_date IN DATE,
        p_batch_id IN NUMBER,
        p_processing_date IN DATE DEFAULT SYSDATE
    );
    
    PROCEDURE cancel_modification(
        p_loan_id IN VARCHAR2,
        p_modification_id IN NUMBER,
        p_cancellation_date IN DATE,
        p_batch_id IN NUMBER
    );
    
    FUNCTION get_active_modifications(
        p_loan_id IN VARCHAR2
    ) RETURN SYS_REFCURSOR;
    
    PROCEDURE update_modification_status(
        p_modification_id IN NUMBER,
        p_new_status IN VARCHAR2,
        p_batch_id IN NUMBER
    );
END loan_modification_pkg;
/