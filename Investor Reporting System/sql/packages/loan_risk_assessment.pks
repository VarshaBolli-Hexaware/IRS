CREATE OR REPLACE PACKAGE loan_risk_assessment_pkg AS
    -- Constants
    c_high_risk_dti CONSTANT NUMBER := 0.43;  -- 43% DTI threshold
    c_high_risk_ltv CONSTANT NUMBER := 0.80;  -- 80% LTV threshold
    c_min_credit_score CONSTANT NUMBER := 620;
    
    -- Types
    TYPE r_risk_metrics IS RECORD (
        loan_id loan_master.loan_id%TYPE,
        risk_score NUMBER,
        risk_category VARCHAR2(20),
        ltv_ratio NUMBER,
        dti_ratio NUMBER,
        credit_score NUMBER
    );
    
    -- Core procedures and functions
    FUNCTION calculate_loan_risk_metrics(
        p_loan_id IN VARCHAR2
    ) RETURN r_risk_metrics;
    
    PROCEDURE update_pool_risk_profile(
        p_pool_id IN VARCHAR2
    );
    
    FUNCTION get_risk_adjusted_rate(
        p_base_rate IN NUMBER,
        p_risk_metrics IN r_risk_metrics
    ) RETURN NUMBER;
    
END loan_risk_assessment_pkg;
/