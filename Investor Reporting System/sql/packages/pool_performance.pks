CREATE OR REPLACE PACKAGE pool_performance_pkg AS
    -- Constants
    c_min_performance_score CONSTANT NUMBER := 0;
    c_max_performance_score CONSTANT NUMBER := 100;
    c_critical_delinquency_threshold CONSTANT NUMBER := 0.1;  -- 10%
    
    -- Types
    TYPE r_performance_metrics IS RECORD (
        pool_id VARCHAR2(20),
        performance_score NUMBER,
        delinquency_rate NUMBER,
        loss_severity NUMBER,
        yield_deviation NUMBER,
        risk_adjusted_return NUMBER,
        stress_test_result VARCHAR2(20)
    );
    
    -- Core procedures and functions
    FUNCTION calculate_performance_metrics(
        p_pool_id IN VARCHAR2,
        p_as_of_date IN DATE DEFAULT SYSDATE
    ) RETURN r_performance_metrics;
    
    PROCEDURE update_pool_performance(
        p_pool_id IN VARCHAR2,
        p_metrics IN r_performance_metrics
    );
    
    FUNCTION run_stress_test(
        p_pool_id IN VARCHAR2,
        p_scenario IN VARCHAR2  -- 'BASE', 'MODERATE', 'SEVERE'
    ) RETURN r_performance_metrics;
    
    PROCEDURE generate_performance_report(
        p_pool_id IN VARCHAR2,
        p_report_date IN DATE DEFAULT SYSDATE
    );
    
END pool_performance_pkg;
/
