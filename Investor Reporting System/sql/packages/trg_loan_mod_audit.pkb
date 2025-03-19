-- Create trigger to track modification changes
CREATE OR REPLACE TRIGGER trg_loan_mod_audit
AFTER INSERT OR UPDATE OR DELETE ON loan_modification_history
FOR EACH ROW
DECLARE
    v_change_type VARCHAR2(20);
    v_old_value VARCHAR2(4000);
    v_new_value VARCHAR2(4000);
BEGIN
    IF INSERTING THEN
        v_change_type := 'INSERT';
        v_old_value := NULL;
        v_new_value := 'New modification: Rate ' || :NEW.new_rate || 
                      ', Term ' || :NEW.new_term ||
                      ', Status ' || :NEW.status;
    ELSIF UPDATING THEN
        v_change_type := 'UPDATE';
        IF :OLD.status != :NEW.status THEN
            v_old_value := 'Status: ' || :OLD.status;
            v_new_value := 'Status: ' || :NEW.status;
        ELSIF :OLD.cancellation_date != :NEW.cancellation_date THEN
            v_old_value := 'Active';
            v_new_value := 'Cancelled on ' || TO_CHAR(:NEW.cancellation_date, 'YYYY-MM-DD');
        END IF;
    ELSE
        v_change_type := 'DELETE';
        v_old_value := 'Modification ID: ' || :OLD.modification_id;
        v_new_value := NULL;
    END IF;
    
    IF v_old_value IS NOT NULL OR v_new_value IS NOT NULL THEN
        INSERT INTO loan_modification_audit (
            audit_id,
            modification_id,
            loan_id,
            change_type,
            old_value,
            new_value,
            change_date,
            changed_by
        ) VALUES (
            mod_audit_seq.NEXTVAL,
            :NEW.modification_id,
            :NEW.loan_id,
            v_change_type,
            v_old_value,
            v_new_value,
            SYSDATE,
            USER
        );
    END IF;
END;
/ 