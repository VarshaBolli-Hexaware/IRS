CREATE OR REPLACE PACKAGE BODY pool_performance_pkg AS
    
    FUNCTION calculate_base_score(
        p_pool_id IN VARCHAR2,
        p_risk_metrics IN loan_risk_assessment_pkg.r_risk_metrics,
        p_cash_flows IN cash_flow_pkg.t_cash_flow_table
    ) RETURN NUMBER IS
        v_score NUMBER := 50;  -- Start at neutral score
        v_total_cash_flow NUMBER := 0;
        v_expected_cash_flow NUMBER := 0;
    BEGIN
        -- Adjust score based on risk metrics
        v_score := v_score - (p_risk_metrics.risk_score / 2);
        
        -- Calculate cash flow performance
        FOR i IN 1..p_cash_flows.COUNT LOOP
            v_total_cash_flow := v_total_cash_flow + p_cash_flows(i).net_cash_flow;
            v_expected_cash_flow := v_expected_cash_flow + 
                (p_cash_flows(i).scheduled_principal + p_cash_flows(i).scheduled_interest);
        END LOOP;
        
        -- Adjust score based on cash flow performance
        IF v_total_cash_flow >= v_expected_cash_flow THEN
            v_score := v_score + 20;  -- Exceeding expectations
        ELSIF v_total_cash_flow >= (v_expected_cash_flow * 0.9) THEN
            v_score := v_score + 10;  -- Meeting expectations
        ELSE
            v_score := v_score - 20;  -- Below expectations
        END IF;
        
        RETURN GREATEST(c_min_performance_score, 
                       LEAST(c_max_performance_score, v_score));
    END calculate_base_score;
    
    FUNCTION calculate_performance_metrics(
        p_pool_id IN VARCHAR2,
        p_as_of_date IN DATE DEFAULT SYSDATE
    ) RETURN r_performance_metrics IS
        v_metrics r_performance_metrics;
        v_risk_metrics loan_risk_assessment_pkg.r_risk_metrics;
        v_cash_flows cash_flow_pkg.t_cash_flow_table;
        v_pool_value NUMBER;
        v_yield_rate NUMBER;
    BEGIN
        v_metrics.pool_id := p_pool_id;
        
        -- Get risk metrics
        SELECT *
        INTO v_risk_metrics
        FROM TABLE(loan_risk_assessment_pkg.calculate_loan_risk_metrics(p_pool_id));
        
        -- Get projected cash flows
        SELECT *
        BULK COLLECT INTO v_cash_flows
        FROM TABLE(cash_flow_pkg.project_cash_flows(p_pool_id));
        
        -- Calculate base performance score
        v_metrics.performance_score := calculate_base_score(
            p_pool_id, v_risk_metrics, v_cash_flows
        );
        
        -- Get pool valuation metrics
        SELECT market_value, yield_rate
        INTO v_pool_value, v_yield_rate
        FROM pool_definition
        WHERE pool_id = p_pool_id;
        
        -- Calculate yield deviation
        v_metrics.yield_deviation := v_yield_rate - 
            pool_valuation_pkg.calculate_pool_metrics(p_pool_id).yield_rate;
        
        -- Calculate risk-adjusted return
        v_metrics.risk_adjusted_return := 
            (v_yield_rate - v_metrics.yield_deviation) / v_risk_metrics.risk_score;
        
        -- Get delinquency rate
        SELECT COUNT(CASE WHEN status = 'DELINQUENT' THEN 1 END) / COUNT(*) * 100
        INTO v_metrics.delinquency_rate
        FROM loan_master l
        JOIN pool_loan_xref x ON l.loan_id = x.loan_id
        WHERE x.pool_id = p_pool_id;
        
        -- Calculate loss severity
        v_metrics.loss_severity := 
            NVL(SUM(CASE WHEN status = 'DEFAULT' 
                        THEN (original_balance - current_balance) / original_balance 
                        ELSE 0 END) / 
                NULLIF(COUNT(CASE WHEN status = 'DEFAULT' THEN 1 END), 0), 0) * 100
        FROM loan_master l
        JOIN pool_loan_xref x ON l.loan_id = x.loan_id
        WHERE x.pool_id = p_pool_id;
        
        -- Determine stress test result
        v_metrics.stress_test_result := 
            CASE 
                WHEN v_metrics.delinquency_rate > c_critical_delinquency_threshold THEN 'CRITICAL'
                WHEN v_metrics.performance_score < 40 THEN 'WARNING'
                ELSE 'STABLE'
            END;
        
        RETURN v_metrics;
    EXCEPTION
        WHEN OTHERS THEN
            investor_reporting_pkg.log_exception(
                p_pool_id,
                NULL,
                'PERFORMANCE_METRICS',
                'HIGH',
                'Error calculating performance metrics: ' || SQLERRM
            );
            RAISE;
    END calculate_performance_metrics;
    
    PROCEDURE update_pool_performance(
        p_pool_id IN VARCHAR2,
        p_metrics IN r_performance_metrics
    ) IS
    BEGIN
        -- Update pool performance metrics
        UPDATE pool_definition
        SET performance_score = p_metrics.performance_score,
            delinquency_rate = p_metrics.delinquency_rate,
            loss_severity = p_metrics.loss_severity,
            last_performance_update = SYSDATE
        WHERE pool_id = p_pool_id;
        
        -- If performance is critical, notify risk management
        IF p_metrics.stress_test_result = 'CRITICAL' THEN
            investor_reporting_pkg.log_exception(
                p_pool_id,
                NULL,
                'PERFORMANCE_ALERT',
                'HIGH',
                'Pool performance has reached critical levels'
            );
        END IF;
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            investor_reporting_pkg.log_exception(
                p_pool_id,
                NULL,
                'PERFORMANCE_UPDATE',
                'HIGH',
                'Error updating pool performance: ' || SQLERRM
            );
            RAISE;
    END update_pool_performance;
    
    FUNCTION run_stress_test(
        p_pool_id IN VARCHAR2,
        p_scenario IN VARCHAR2
    ) RETURN r_performance_metrics IS
        v_base_metrics r_performance_metrics;
        v_stressed_metrics r_performance_metrics;
        v_stress_factor NUMBER;
    BEGIN
        -- Get base metrics
        v_base_metrics := calculate_performance_metrics(p_pool_id);
        
        -- Set stress factor based on scenario
        v_stress_factor := 
            CASE p_scenario
                WHEN 'BASE' THEN 1.0
                WHEN 'MODERATE' THEN 1.5
                WHEN 'SEVERE' THEN 2.0
                ELSE 1.0
            END;
        
        -- Apply stress factors to metrics
        v_stressed_metrics := v_base_metrics;
        v_stressed_metrics.delinquency_rate := 
            LEAST(100, v_base_metrics.delinquency_rate * v_stress_factor);
        v_stressed_metrics.loss_severity := 
            LEAST(100, v_base_metrics.loss_severity * v_stress_factor);
        v_stressed_metrics.performance_score := 
            GREATEST(0, v_base_metrics.performance_score / v_stress_factor);
        
        RETURN v_stressed_metrics;
    EXCEPTION
        WHEN OTHERS THEN
            investor_reporting_pkg.log_exception(
                p_pool_id,
                NULL,
                'STRESS_TEST',
                'HIGH',
                'Error running stress test: ' || SQLERRM
            );
            RAISE;
    END run_stress_test;
    
    PROCEDURE generate_performance_report(
        p_pool_id IN VARCHAR2,
        p_report_date IN DATE DEFAULT SYSDATE
    ) IS
        v_metrics r_performance_metrics;
        v_stressed_metrics r_performance_metrics;
        v_report_id NUMBER;
    BEGIN
        -- Calculate current metrics
        v_metrics := calculate_performance_metrics(p_pool_id, p_report_date);
        
        -- Run stress tests
        v_stressed_metrics := run_stress_test(p_pool_id, 'SEVERE');
        
        -- Generate report content
        INSERT INTO monthly_reports (
            report_id,
            pool_id,
            report_date,
            report_content,
            created_date,
            created_by
        ) VALUES (
            monthly_report_seq.NEXTVAL,
            p_pool_id,
            p_report_date,
            'Pool Performance Report' || CHR(10) ||
            '======================' || CHR(10) ||
            'Performance Score: ' || TO_CHAR(v_metrics.performance_score) || CHR(10) ||
            'Delinquency Rate: ' || TO_CHAR(v_metrics.delinquency_rate, '990.99') || '%' || CHR(10) ||
            'Loss Severity: ' || TO_CHAR(v_metrics.loss_severity, '990.99') || '%' || CHR(10) ||
            'Risk-Adjusted Return: ' || TO_CHAR(v_metrics.risk_adjusted_return, '990.99') || CHR(10) ||
            'Stress Test Result: ' || v_metrics.stress_test_result || CHR(10) ||
            'Stressed Performance Score: ' || TO_CHAR(v_stressed_metrics.performance_score) || CHR(10) ||
            'Stressed Delinquency Rate: ' || TO_CHAR(v_stressed_metrics.delinquency_rate, '990.99') || '%',
            SYSDATE,
            USER
        ) RETURNING report_id INTO v_report_id;
        
        -- Update pool performance
        update_pool_performance(p_pool_id, v_metrics);
        
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            investor_reporting_pkg.log_exception(
                p_pool_id,
                NULL,
                'PERFORMANCE_REPORT',
                'HIGH',
                'Error generating performance report: ' || SQLERRM
            );
            RAISE;
    END generate_performance_report;
    
END pool_performance_pkg;
/ 