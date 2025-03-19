CREATE OR REPLACE PACKAGE investor_reporting_pkg AS
    -- Constants
    c_version CONSTANT VARCHAR2(10) := '1.0.0';
    
    -- Exception definitions
    e_invalid_pool EXCEPTION;
    e_invalid_date EXCEPTION;
    e_processing_error EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_pool, -20001);
    PRAGMA EXCEPTION_INIT(e_invalid_date, -20002);
    PRAGMA EXCEPTION_INIT(e_processing_error, -20003);
    
    -- Type definitions
    TYPE t_loan_record IS RECORD (
        loan_id loan_master.loan_id%TYPE,
        current_balance loan_master.current_balance%TYPE,
        scheduled_payment NUMBER,
        interest_portion NUMBER,
        principal_portion NUMBER
    );
    TYPE t_loan_table IS TABLE OF t_loan_record;
    
    -- Core procedures and functions
    PROCEDURE process_remittance(
        p_pool_id IN VARCHAR2,
        p_remittance_date IN DATE,
        p_remittance_id OUT NUMBER
    );
    
    PROCEDURE generate_monthly_report(
        p_pool_id IN VARCHAR2,
        p_report_date IN DATE
    );
    
    PROCEDURE calculate_pool_statistics(
        p_pool_id IN VARCHAR2,
        p_calculation_date IN DATE
    );
    
    FUNCTION validate_pool_status(
        p_pool_id IN VARCHAR2
    ) RETURN BOOLEAN;
    
    PROCEDURE log_exception(
        p_pool_id IN VARCHAR2,
        p_loan_id IN VARCHAR2,
        p_exception_type IN VARCHAR2,
        p_severity IN VARCHAR2,
        p_description IN VARCHAR2
    );
    
    -- Utility procedures
    PROCEDURE update_pool_factor(
        p_pool_id IN VARCHAR2,
        p_new_factor IN NUMBER
    );
    
    PROCEDURE process_loan_payoff(
        p_loan_id IN VARCHAR2,
        p_payoff_date IN DATE,
        p_payoff_amount IN NUMBER
    );
END investor_reporting_pkg;
/