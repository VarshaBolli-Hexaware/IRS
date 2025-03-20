CREATE OR REPLACE PACKAGE BODY cash_flow_pkg AS
    FUNCTION calculate_period_cash_flow(
        p_pool_id IN VARCHAR2,
        p_period IN NUMBER,
        p_risk_metrics IN loan_risk_assessment_pkg.r_risk_metrics
    ) RETURN r_cash_flow IS
        v_cash_flow r_cash_flow;
        v_pool_balance NUMBER;
        v_wac_rate NUMBER;
        v_psa_factor NUMBER;
        v_default_rate NUMBER;
    BEGIN
        -- Get pool details
        SELECT current_amount, weighted_rate
        INTO v_pool_balance, v_wac_rate
        FROM pool_definition
        WHERE pool_id = p_pool_id;
        
        -- Calculate PSA factor based on loan age
        v_psa_factor := LEAST(1, p_period/30) * c_prepayment_multiplier;
        
        -- Adjust prepayment speed based on risk metrics
        IF p_risk_metrics.risk_category = 'HIGH_RISK' THEN
            v_psa_factor := v_psa_factor * 1.2;  -- 20% faster prepayment for high risk
        END IF;
        
        -- Calculate default rate based on risk score
        v_default_rate := (p_risk_metrics.risk_score / 100) * 0.02 / 12;  -- Annual to monthly
        
        -- Calculate scheduled principal (simplified)
        v_cash_flow.scheduled_principal := v_pool_balance / 360;
        
        -- Calculate scheduled interest
        v_cash_flow.scheduled_interest := v_pool_balance * v_wac_rate / 12;
        
        -- Calculate prepayment
        v_cash_flow.prepayment := (v_pool_balance - v_cash_flow.scheduled_principal) * v_psa_factor;
        
        -- Calculate defaults
        v_cash_flow.default_amount := v_pool_balance * v_default_rate * c_default_severity;
        
        -- Calculate net cash flow
        v_cash_flow.net_cash_flow := 
            v_cash_flow.scheduled_principal +
            v_cash_flow.scheduled_interest +
            v_cash_flow.prepayment -
            v_cash_flow.default_amount;
            
        v_cash_flow.period := p_period;
        
        RETURN v_cash_flow;
    END calculate_period_cash_flow;
    
    FUNCTION project_cash_flows(
        p_pool_id IN VARCHAR2,
        p_projection_months IN NUMBER DEFAULT 360
    ) RETURN t_cash_flow_table PIPELINED IS
        v_risk_metrics loan_risk_assessment_pkg.r_risk_metrics;
        v_cash_flow r_cash_flow;
    BEGIN
        -- Get pool risk metrics
        SELECT *
        INTO v_risk_metrics
        FROM TABLE(loan_risk_assessment_pkg.calculate_loan_risk_metrics(p_pool_id));
        
        -- Project cash flows for each period
        FOR i IN 1..p_projection_months LOOP
            v_cash_flow := calculate_period_cash_flow(p_pool_id, i, v_risk_metrics);
            PIPE ROW(v_cash_flow);
        END LOOP;
        
        RETURN;
    EXCEPTION
        WHEN OTHERS THEN
            investor_reporting_pkg.log_exception(
                p_pool_id,
                NULL,
                'CASH_FLOW_PROJECTION',
                'HIGH',
                'Error projecting cash flows: ' || SQLERRM
            );
            RAISE;
    END project_cash_flows;
    
    FUNCTION calculate_pool_duration(
        p_pool_id IN VARCHAR2,
        p_yield_rate IN NUMBER
    ) RETURN NUMBER IS
        v_duration NUMBER := 0;
        v_total_pv NUMBER := 0;
        v_monthly_yield NUMBER;
        v_cash_flows t_cash_flow_table;
    BEGIN
        v_monthly_yield := p_yield_rate / 12;
        
        -- Get projected cash flows
        SELECT *
        BULK COLLECT INTO v_cash_flows
        FROM TABLE(project_cash_flows(p_pool_id));
        
        -- Calculate Macaulay duration
        FOR i IN 1..v_cash_flows.COUNT LOOP
            v_duration := v_duration + 
                (i * v_cash_flows(i).net_cash_flow / POWER(1 + v_monthly_yield, i));
            v_total_pv := v_total_pv +
                (v_cash_flows(i).net_cash_flow / POWER(1 + v_monthly_yield, i));
        END LOOP;
        
        -- Convert to Modified duration
        RETURN (v_duration / v_total_pv) / (1 + v_monthly_yield);
    EXCEPTION
        WHEN OTHERS THEN
            investor_reporting_pkg.log_exception(
                p_pool_id,
                NULL,
                'DURATION_CALCULATION',
                'HIGH',
                'Error calculating duration: ' || SQLERRM
            );
            RAISE;
    END calculate_pool_duration;
    
    FUNCTION calculate_pool_convexity(
        p_pool_id IN VARCHAR2,
        p_yield_rate IN NUMBER,
        p_duration IN NUMBER
    ) RETURN NUMBER IS
        v_convexity NUMBER := 0;
        v_total_pv NUMBER := 0;
        v_monthly_yield NUMBER;
        v_cash_flows t_cash_flow_table;
    BEGIN
        v_monthly_yield := p_yield_rate / 12;
        
        -- Get projected cash flows
        SELECT *
        BULK COLLECT INTO v_cash_flows
        FROM TABLE(project_cash_flows(p_pool_id));
        
        -- Calculate convexity
        FOR i IN 1..v_cash_flows.COUNT LOOP
            v_convexity := v_convexity + 
                (i * (i + 1) * v_cash_flows(i).net_cash_flow / 
                 POWER(1 + v_monthly_yield, i));
            v_total_pv := v_total_pv +
                (v_cash_flows(i).net_cash_flow / POWER(1 + v_monthly_yield, i));
        END LOOP;
        
        RETURN v_convexity / (v_total_pv * POWER(1 + v_monthly_yield, 2));
    EXCEPTION
        WHEN OTHERS THEN
            investor_reporting_pkg.log_exception(
                p_pool_id,
                NULL,
                'CONVEXITY_CALCULATION',
                'HIGH',
                'Error calculating convexity: ' || SQLERRM
            );
            RAISE;
    END calculate_pool_convexity;
    
END cash_flow_pkg;
/ 
