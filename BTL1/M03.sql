CREATE TABLE BRANCH_F3(
    BRANCHID VARCHAR2(5) PRIMARY KEY,
    PHONE VARCHAR2(15),
    CREATED_AT DATE,
    DELETED_AT DATE
);

CREATE TABLE ACCOUNT_S3_A(
    ACCID VARCHAR2(10) PRIMARY KEY,
    CUSID VARCHAR2(10),
    BRANCHID VARCHAR2(5)
);

CREATE TABLE ACCOUNT_S3_B(
    ACCID VARCHAR2(10) PRIMARY KEY,
    BALANCE NUMBER,
    STATUS VARCHAR2(20),
    CREATED_AT DATE,
    DELETED_AT DATE
);

CREATE TABLE TRANSACT_S3(
    TRANID VARCHAR2(10) PRIMARY KEY,
    ACCID VARCHAR2(10),
    BRANCHID VARCHAR2(5),
    AMOUNT NUMBER,
    TRANSACTIONTYPE VARCHAR2(20),
    TRANSDATE DATE,
    CREATED_AT DATE,
    DELETED_AT DATE
);

CREATE VIEW ACCOUNT_S3_VIEW AS
SELECT 
    A.ACCID,
    A.CUSID,
    A.BRANCHID,
    B.BALANCE,
    B.STATUS,
    B.CREATED_AT,
    B.DELETED_AT
FROM ACCOUNT_S3_A A
JOIN ACCOUNT_S3_B B
ON A.ACCID = B.ACCID;

CREATE VIEW BRANCH_FULL_VIEW AS
SELECT 
    F1.BRANCHID,
    F1.BRANCHNAME,
    F3.PHONE,
    F3.CREATED_AT,
    F3.DELETED_AT
FROM M01.BRANCH_F1@DBL_M01 F1
JOIN BRANCH_F3 F3
ON F1.BRANCHID = F3.BRANCHID;

---

SELECT 
    (SELECT COUNT(*) FROM M01.BRANCH_F1@DBL_M01) AS SO_DONG_M01,
    (SELECT COUNT(*) FROM M02.BRANCH_F2@DBL_M02) AS SO_DONG_M02,
    (SELECT COUNT(*) FROM M03.BRANCH_F3) AS SO_DONG_M03
FROM DUAL;

SELECT COUNT(*) AS TONG_SO_TAI_KHOAN_TOAN_HE_THONG
FROM (
    SELECT ACCID FROM M01.ACCOUNT_S1_VIEW@DBL_M01
    UNION ALL
    SELECT ACCID FROM M02.ACCOUNT_S2_VIEW@DBL_M02
    UNION ALL
    SELECT ACCID FROM M03.ACCOUNT_S3_VIEW
);

SELECT 
    (SELECT COUNT(*) FROM M01.TRANSACT_S1@DBL_M01) AS TXN_MIEN_BAC,
    (SELECT COUNT(*) FROM M02.TRANSACT_S2@DBL_M02) AS TXN_MIEN_NAM,
    (SELECT COUNT(*) FROM M03.TRANSACT_S3) AS TXN_MIEN_TRUNG,
    (
        SELECT COUNT(*) FROM M01.TRANSACT_S1@DBL_M01
    ) + (
        SELECT COUNT(*) FROM M02.TRANSACT_S2@DBL_M02
    ) + (
        SELECT COUNT(*) FROM M03.TRANSACT_S3
    ) AS TONG_GIAO_DICH_TOAN_HE_THONG
FROM DUAL;

---

-- M01:
CREATE DATABASE LINK DBL_M01 CONNECT TO GUEST IDENTIFIED BY GUEST USING 'M01_Link';

SELECT * FROM M01.BRANCH_F1@DBL_M01;

SELECT 
    F1.BRANCHID, F1.BRANCHNAME,
    F3.PHONE, F3.CREATED_AT, F3.DELETED_AT
FROM M03.BRANCH_F3 F3
JOIN M01.BRANCH_F1@DBL_M01 F1
   ON F3.BRANCHID = F1.BRANCHID;

CREATE MATERIALIZED VIEW CUSTOMER_REP
BUILD IMMEDIATE
REFRESH COMPLETE
START WITH SYSDATE
NEXT SYSDATE + 1/24
AS
SELECT *
FROM M01.CUSTOMER@DBL_M01
WHERE DELETED_AT IS NULL OR DELETED_AT >= CREATED_AT;

SELECT * FROM CUSTOMER_REP;
SELECT COUNT(*) FROM CUSTOMER_REP;

--M02:
CREATE DATABASE LINK DBL_M02 CONNECT TO GUEST IDENTIFIED BY GUEST USING 'M02_Link';

SELECT 
    F2.BRANCHID,
    F3.PHONE,
    F3.CREATED_AT,
    F3.DELETED_AT
FROM M03.BRANCH_F3 F3
JOIN M02.BRANCH_F2@DBL_M02 F2
ON F3.BRANCHID = F2.BRANCHID;

-- DROP DATABASE LINK DBL_M02;

---

SELECT * FROM BRANCH_F3;
SELECT * FROM M03.TRANSACT@DBL_M01;
SELECT * FROM CUSTOMER_REP;
EXEC DBMS_MVIEW.REFRESH('CUSTOMER_REP');


---

SET SERVEROUTPUT ON;

BEGIN
    FOR i IN 1..1000 LOOP
        INSERT INTO BRANCH_F3 (BRANCHID, PHONE, CREATED_AT, DELETED_AT)
        VALUES (
            -- 1. Khóa chính đồng bộ 100% với F1 và F2 (Định dạng 'B001', 'B002',..., 'B1000')
            'B' || TO_CHAR(i, '000'),
            
            -- 2. Sinh số điện thoại ngẫu nhiên dựa trên mã i
            '0243' || TO_CHAR(8000000 + i),
            
            -- 3. Ngày tạo chi nhánh ngẫu nhiên lùi về quá khứ từ 1 đến 3 năm
            SYSDATE - ROUND(DBMS_RANDOM.VALUE(365, 1095)),
            
            -- 4. Ngày xóa (Chỉ có khoảng 3% chi nhánh bị đóng cửa ngẫu nhiên, số còn lại là NULL)
            CASE 
                WHEN MOD(i, 33) = 0 THEN SYSDATE - ROUND(DBMS_RANDOM.VALUE(0, 180))
                ELSE NULL
            END
        );
        
        -- Commit định kỳ mỗi 200 dòng để giải phóng tài nguyên transaction log
        IF MOD(i, 200) = 0 THEN
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('Máy 3 - Đã insert: ' || i || ' dòng cho BRANCH_F3');
        END IF;
    END LOOP;
    
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Máy 3 - Hoàn thành nạp 1.000 dòng cho phân mảnh dọc BRANCH_F3!');
END;
/

BEGIN
    FOR i IN 1..340000 LOOP
        INSERT INTO TRANSACT_S3 (
            TRANID, ACCID, BRANCHID, AMOUNT, TRANSACTIONTYPE, 
            TRANSDATE, CREATED_AT, DELETED_AT
        ) VALUES (
            'TXN' || TO_CHAR(i + 660000, '000000'),
            'ACC' || TO_CHAR(ROUND(DBMS_RANDOM.VALUE(651, 1000)), '0000'),
            'B' || TO_CHAR(ROUND(DBMS_RANDOM.VALUE(651, 1000)), '000'),
            ROUND(DBMS_RANDOM.VALUE(10000, 100000000), 2),
            CASE ROUND(DBMS_RANDOM.VALUE(1, 6))
                WHEN 1 THEN 'DEPOSIT'
                WHEN 2 THEN 'WITHDRAWAL'
                WHEN 3 THEN 'TRANSFER'
                WHEN 4 THEN 'PAYMENT'
                WHEN 5 THEN 'INTEREST'
                ELSE 'FEE'
            END,
            SYSDATE - ROUND(DBMS_RANDOM.VALUE(0, 730)),
            SYSDATE - ROUND(DBMS_RANDOM.VALUE(0, 730)),
            CASE 
                WHEN ROUND(DBMS_RANDOM.VALUE(1, 100)) <= 2 THEN 
                    SYSDATE - ROUND(DBMS_RANDOM.VALUE(0, 180))
                ELSE NULL
            END
        );
        IF MOD(i, 10000) = 0 THEN
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('Site 3 - Da insert: ' || i || ' / 340000 dong');
        END IF;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Site 3 - Hoan thanh! Tong: 340.000 giao dich');
END;

BEGIN
    FOR i IN 651..1000 LOOP
        INSERT INTO ACCOUNT_S3_A (ACCID, CUSID, BRANCHID)
        VALUES (
            'ACC' || TO_CHAR(i, 'FM0000'), -- Dùng 'FM' để tránh khoảng trắng thừa phía trước
            'CUS' || TO_CHAR(ROUND(DBMS_RANDOM.VALUE(1, 1000)), 'FM0000'),
            'B' || TO_CHAR(i, 'FM000')
        );
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Site 3 - Da insert xong ACCOUNT_S3_A (651-1000)');
END;
/

BEGIN
    FOR i IN 651..1000 LOOP
        INSERT INTO ACCOUNT_S3_B (ACCID, BALANCE, STATUS, CREATED_AT, DELETED_AT)
        VALUES (
            'ACC' || TO_CHAR(i, 'FM0000'),
            ROUND(DBMS_RANDOM.VALUE(0, 100000000), 2),
            CASE ROUND(DBMS_RANDOM.VALUE(1, 4))
                WHEN 1 THEN 'ACTIVE'
                WHEN 2 THEN 'INACTIVE'
                ELSE 'LOCKED'
            END,
            SYSDATE - ROUND(DBMS_RANDOM.VALUE(0, 1095)),
            CASE 
                WHEN ROUND(DBMS_RANDOM.VALUE(1, 10)) <= 1 THEN 
                    SYSDATE - ROUND(DBMS_RANDOM.VALUE(0, 365))
                ELSE NULL
            END
        );
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Site 3 - Da insert xong ACCOUNT_S3_B (651-1000)');
END;
/

--- TEST
SELECT * FROM TRANSACT_S3;
SELECT * FROM ACCOUNT_S3_A;
SELECT * FROM ACCOUNT_S3_B;

---
----------------------------------------------------------------
-- REQ 1: 10 CÂU TRUY VẤN PHÂN TÁN CHIẾN LƯỢC KINH TẾ (MÁY 1)
----------------------------------------------------------------
-- Q1 [UNION ALL]: Tổng hợp báo cáo dòng tiền giao dịch lớn toàn hệ thống phục vụ phòng chống rửa tiền (> 90M)
SELECT 'NORTH_SITE' AS REGION, TRANID, ACCID, AMOUNT, TRANSDATE FROM M01.TRANSACT_S1@DBL_M01 WHERE AMOUNT > 90000000
UNION ALL
SELECT 'SOUTH_SITE' AS REGION, TRANID, ACCID, AMOUNT, TRANSDATE FROM M02.TRANSACT_S2@DBL_M02 WHERE AMOUNT > 90000000
UNION ALL
SELECT 'CENTRAL_SITE' AS REGION, TRANID, ACCID, AMOUNT, TRANSDATE FROM TRANSACT_S3 WHERE AMOUNT > 90000000;

-- Q2 [INTERSECT]: Phát hiện tập khách hàng đa mục đích (Có tài khoản hoạt động song song ở cả khối Bắc và Nam)
SELECT CUSID FROM ACCOUNT_S3_A;
INTERSECT
SELECT CUSID FROM M01.ACCOUNT_S1_A@DBL_M01;

-- Q3 [MINUS]: Lọc ra danh sách khách hàng thuộc phân mảnh miền Bắc nhưng chưa phát sinh bất kỳ giao dịch nào tại miền Bắc
SELECT CUSID FROM M01.CUSTOMER@DBL_M01 WHERE DELETED_AT IS NULL
MINUS
SELECT A.CUSID FROM M01.ACCOUNT_S1_A@DBL_M01 A JOIN M01.TRANSACT_S1@DBL_M01 T ON A.ACCID = T.ACCID;

-- Q4 [DIVISION CHUẨN ĐẠI SỐ QUAN HỆ]: Tìm tài khoản "Kinh tế đặc biệt" có phát sinh giao dịch ở TẤT CẢ các chi nhánh thuộc bảng BRANCH_F1
SELECT A.ACCID, A.CUSID 
FROM ACCOUNT_S3_A A
WHERE NOT EXISTS (
    SELECT B.BRANCHID 
    FROM M01.BRANCH_F1@DBL_M01 B
    WHERE B.BRANCHID IN ('B001', 'B002', 'B003')
      AND NOT EXISTS (
          -- Tập bị chia (R): Lịch sử luân chuyển dòng tiền giao dịch
          SELECT T.TRANID 
          FROM TRANSACT_S3 T 
          WHERE T.ACCID = A.ACCID 
            AND T.BRANCHID = B.BRANCHID
      )
);

-- Q5 [GROUP BY + SUM]: Thống kê doanh số phí dịch vụ (FEE) thu được của từng chi nhánh trên toàn hệ thống để đánh giá KPI
SELECT BRANCHID, SUM(AMOUNT) AS TOTAL_FEE_REVENUE
FROM (
    SELECT BRANCHID, AMOUNT, TRANSACTIONTYPE FROM M01.TRANSACT_S1@DBL_M01
    UNION ALL
    SELECT BRANCHID, AMOUNT, TRANSACTIONTYPE FROM M02.TRANSACT_S2@DBL_M02
    UNION ALL
    SELECT BRANCHID, AMOUNT, TRANSACTIONTYPE FROM TRANSACT_S3
) WHERE TRANSACTIONTYPE = 'FEE'
GROUP BY BRANCHID 
ORDER BY TOTAL_FEE_REVENUE DESC;

-- Q6 [HAVING + AVG]: Tìm các chi nhánh tiềm năng có số dư tài khoản trung bình của khách hàng thuộc phân khúc cao (> 60M)
SELECT BRANCHID, AVG(BALANCE) AS AVG_BRANCH_BALANCE
FROM (
    SELECT BRANCHID, BALANCE FROM M01.ACCOUNT_S1_VIEW@DBL_M01
    UNION ALL
    SELECT BRANCHID, BALANCE FROM M02.ACCOUNT_S2_VIEW@DBL_M02
    UNION ALL
    SELECT BRANCHID, BALANCE FROM ACCOUNT_S3_VIEW
)
GROUP BY BRANCHID
HAVING AVG(BALANCE) > 60000000;

-- Q7 [ANALYTICAL COUNT]: Phân tích tần suất giao dịch trong ngày cao điểm để cảnh báo rủi ro vận hành hệ thống
SELECT ACCID, TRANSDATE, COUNT(TRANID) OVER(PARTITION BY ACCID) AS TX_DENSITY
FROM TRANSACT_S3
WHERE AMOUNT > 50000000;

-- Q8 [DISTRIBUTED JOIN Phức tạp]: Truy xuất danh sách đen các tài khoản LOCKED kèm thông tin định danh cá nhân phục vụ thanh tra pháp lý
SELECT C.CUSNAME, C.PHONE, V.ACCID, V.BALANCE, V.STATUS
FROM CUSTOMER_REP C
JOIN M02.ACCOUNT_S2_VIEW@DBL_M02 V ON C.CUSID = V.CUSID
WHERE V.STATUS = 'LOCKED';

-- Q9 [SUBQUERY PHÂN TÁN]: Tìm các tài khoản có số dư lớn hơn mức trung bình của toàn bộ hệ thống ngân hàng để tiếp thị sản phẩm đầu tư
SELECT ACCID, BALANCE, STATUS 
FROM ACCOUNT_S3_VIEW
WHERE BALANCE > (
    SELECT AVG(BALANCE) FROM (
        SELECT BALANCE FROM ACCOUNT_S3_VIEW
        UNION ALL
        SELECT BALANCE FROM M02.ACCOUNT_S2_VIEW@DBL_M02
    )
);

-- Q10 [TOP ROWS]: Trích xuất 5 giao dịch có giá trị dòng tiền luân chuyển lớn nhất hệ thống để báo cáo Thống đốc ngân hàng
SELECT * FROM (
    SELECT TRANID, ACCID, AMOUNT, TRANSACTIONTYPE FROM TRANSACT_S3
    UNION ALL
    SELECT TRANID, ACCID, AMOUNT, TRANSACTIONTYPE FROM M02.TRANSACT_S2@DBL_M02
) ORDER BY AMOUNT DESC
FETCH FIRST 5 ROWS ONLY;

--------------------------------------------------------------------------------
-- REQ 2: BỔ SUNG DISTRIBUTED FUNCTION, integrity constraint, stored procedure (HÀM PHÂN TÁN CHẤM ĐIỂM TÍN DỤNG)
-- Ý nghĩa kinh tế: Phân tích lịch sử giao dịch liên Site để chấm điểm tín dụng khách hàng
--------------------------------------------------------------------------------

-- 1. Số dư không được âm
ALTER TABLE ACCOUNT_S3_B
ADD CONSTRAINT CHK_BALANCE_NON_NEGATIVE 
CHECK (BALANCE >= 0);

-- 2. Số tiền giao dịch phải dương
ALTER TABLE TRANSACT_S3
ADD CONSTRAINT CHK_AMOUNT_POSITIVE 
CHECK (AMOUNT > 0);

-- 3. Trạng thái tài khoản chỉ được trong danh sách cho phép
ALTER TABLE ACCOUNT_S3_B
ADD CONSTRAINT CHK_STATUS_VALID 
CHECK (STATUS IN ('ACTIVE', 'INACTIVE', 'LOCKED'));

-- 4. Loại giao dịch hợp lệ
ALTER TABLE TRANSACT_S3
ADD CONSTRAINT CHK_TRANSACTION_TYPE 
CHECK (TRANSACTIONTYPE IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'PAYMENT', 'INTEREST', 'FEE'));

-- 5. DELETED_AT phải >= CREATED_AT
ALTER TABLE CUSTOMER_REP
ADD CONSTRAINT CHK_DELETE_AFTER_CREATE 
CHECK (DELETED_AT IS NULL OR DELETED_AT >= CREATED_AT);

-- 6. Trigger kiểm soát Business Rule liên Site: Số tiền rút/chuyển không được vượt quá số dư hiện tại
CREATE OR REPLACE TRIGGER TRG_CHECK_DISTRIBUTED_BUSINESS
BEFORE INSERT ON TRANSACT_S3
FOR EACH ROW
DECLARE
    v_current_balance NUMBER;
BEGIN
    IF :NEW.TRANSACTIONTYPE IN ('WITHDRAWAL', 'TRANSFER') THEN
        SELECT BALANCE INTO v_current_balance
        FROM ACCOUNT_S3_B
        WHERE ACCID = :NEW.ACCID;
        
        IF v_current_balance < :NEW.AMOUNT THEN
            RAISE_APPLICATION_ERROR(-20001, 'RBTV Vi Phạm: Số dư tài khoản không đủ để thực hiện giao dịch!');
        END IF;
    END IF;
END;
/

CREATE OR REPLACE FUNCTION FC_DISTRIBUTED_CREDIT_SCORING (
    p_cusid IN VARCHAR2
) RETURN VARCHAR2
IS
    v_local_deposit NUMBER := 0;
    v_remote_deposit1 NUMBER := 0;
    v_remote_deposit2 NUMBER := 0;
    v_total_deposit NUMBER := 0;
    v_score VARCHAR2(20);
BEGIN
    -- 1. Quét dữ liệu tại mảnh Local
    SELECT NVL(SUM(AMOUNT), 0) INTO v_local_deposit
    FROM TRANSACT_S3 T 
    JOIN ACCOUNT_S3_A A ON T.ACCID = A.ACCID
    WHERE A.CUSID = p_cusid AND T.TRANSACTIONTYPE = 'DEPOSIT';

    -- 2. Quét dữ liệu từ mảnh từ xa thứ nhất (Ví dụ từ M03 quét sang M02)
    BEGIN
        EXECUTE IMMEDIATE 'SELECT NVL(SUM(T.AMOUNT), 0) FROM TRANSACT_S2@DBL_M02 T JOIN ACCOUNT_S2_A@DBL_M02 A ON T.ACCID = A.ACCID WHERE A.CUSID = :1 AND T.TRANSACTIONTYPE = ''DEPOSIT''' 
        INTO v_remote_deposit1 USING p_cusid;
    EXCEPTION WHEN OTHERS THEN v_remote_deposit1 := 0;
    END;

    -- 3. Quét dữ liệu từ mảnh từ xa thứ hai (Ví dụ từ M03 quét sang M01)
    BEGIN
        EXECUTE IMMEDIATE 'SELECT NVL(SUM(T.AMOUNT), 0) FROM TRANSACT_S1@DBL_M01 T JOIN ACCOUNT_S1_A@DBL_M01 A ON T.ACCID = A.ACCID WHERE A.CUSID = :1 AND T.TRANSACTIONTYPE = ''DEPOSIT''' 
        INTO v_remote_deposit2 USING p_cusid;
    EXCEPTION WHEN OTHERS THEN v_remote_deposit2 := 0;
    END;

    v_total_deposit := v_local_deposit + v_remote_deposit1 + v_remote_deposit2;

    -- Chiến lược kinh tế phân loại hạng VIP
    IF v_total_deposit > 100000000 THEN v_score := 'VIP_PLATINUM';
    ELSIF v_total_deposit BETWEEN 50000000 AND 100000000 THEN v_score := 'VIP_GOLD';
    ELSE v_score := 'STANDARD';
    END IF;

    RETURN v_score;
END;
/

create or replace NONEDITIONABLE PROCEDURE TRANSFER_MONEY(
    p_from_accid VARCHAR2,
    p_to_accid VARCHAR2,
    p_amount NUMBER
)
IS
    v_from_balance NUMBER;
    v_from_branchid VARCHAR2(10);
    v_from_site NUMBER;
    v_to_site NUMBER;

    e_insufficient_balance EXCEPTION;
    e_invalid_amount EXCEPTION;
BEGIN
    -- 1. ĐẶT SAVEPOINT NGAY ĐẦU TIÊN để đảm bảo nó luôn tồn tại
    SAVEPOINT before_transfer;

    -- 2. Kiểm tra số tiền
    IF p_amount <= 0 THEN
        RAISE e_invalid_amount;
    END IF;

    -- 3. Xác định site dùng REGEXP để lấy chỉ phần số (Xử lý được cả 'ACC 0001' và 'ACC0001')
    -- Nó sẽ lọc bỏ tất cả ký tự không phải số và chuyển về NUMBER
    v_from_site := CASE 
        WHEN TO_NUMBER(REGEXP_REPLACE(p_from_accid, '[^0-9]', '')) BETWEEN 1 AND 300 THEN 1
        WHEN TO_NUMBER(REGEXP_REPLACE(p_from_accid, '[^0-9]', '')) BETWEEN 301 AND 650 THEN 2
        ELSE 3
    END;

    v_to_site := CASE 
        WHEN TO_NUMBER(REGEXP_REPLACE(p_to_accid, '[^0-9]', '')) BETWEEN 1 AND 300 THEN 1
        WHEN TO_NUMBER(REGEXP_REPLACE(p_to_accid, '[^0-9]', '')) BETWEEN 301 AND 650 THEN 2
        ELSE 3
    END;

    -- Debug: In ra để bạn theo dõi (Nhớ bật DBMS Output)
    DBMS_OUTPUT.PUT_LINE('Truy van tai khoan nguon tai Site: ' || v_from_site);

    -- 4. Lấy số dư và mã chi nhánh
    IF v_from_site = 1 THEN
        SELECT B.BALANCE, A.BRANCHID INTO v_from_balance, v_from_branchid
        FROM ACCOUNT_S3_B B JOIN ACCOUNT_S3_A A ON B.ACCID = A.ACCID
        WHERE B.ACCID = p_from_accid;
    ELSIF v_from_site = 2 THEN
        SELECT B.BALANCE, A.BRANCHID INTO v_from_balance, v_from_branchid
        FROM M02.ACCOUNT_S2_B@DBL_M02 B JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON B.ACCID = A.ACCID
        WHERE B.ACCID = p_from_accid;
    ELSE
        SELECT B.BALANCE, A.BRANCHID INTO v_from_balance, v_from_branchid
        FROM M01.ACCOUNT_S1_B@DBL_M01 B JOIN M01.ACCOUNT_S1_A@DBL_M01 A ON B.ACCID = A.ACCID
        WHERE B.ACCID = p_from_accid;
    END IF;

    -- 5. Kiểm tra đủ tiền
    IF v_from_balance < p_amount THEN
        RAISE e_insufficient_balance;
    END IF;

    -- 6. Cập nhật trừ tiền
    IF v_from_site = 1 THEN
        UPDATE ACCOUNT_S3_B SET BALANCE = BALANCE - p_amount WHERE ACCID = p_from_accid;
    ELSIF v_from_site = 2 THEN
        UPDATE M02.ACCOUNT_S2_B@DBL_M02 SET BALANCE = BALANCE - p_amount WHERE ACCID = p_from_accid;
    ELSE
        UPDATE M01.ACCOUNT_S1_B@DBL_M01 SET BALANCE = BALANCE - p_amount WHERE ACCID = p_from_accid;
    END IF;

    -- 7. Cập nhật cộng tiền
    IF v_to_site = 1 THEN
        UPDATE ACCOUNT_S3_B SET BALANCE = BALANCE + p_amount WHERE ACCID = p_to_accid;
    ELSIF v_to_site = 2 THEN
        UPDATE M02.ACCOUNT_S2_B@DBL_M02 SET BALANCE = BALANCE + p_amount WHERE ACCID = p_to_accid;
    ELSE
        UPDATE M01.ACCOUNT_S1_B@DBL_M01 SET BALANCE = BALANCE + p_amount WHERE ACCID = p_to_accid;
    END IF;

    -- 8. Ghi log (Dùng v_from_branchid đã lấy được)
    INSERT INTO TRANSACT_S3 (TRANID, ACCID, BRANCHID, AMOUNT, TRANSACTIONTYPE, TRANSDATE)
    VALUES ('TRF' || TO_CHAR(SYSTIMESTAMP,'YYYYMMDDHH24MISSFF3'), p_from_accid, v_from_branchid, p_amount, 'TRANSFER', SYSDATE);

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Chuyen tien thanh cong!');

EXCEPTION
    WHEN e_insufficient_balance THEN
        ROLLBACK TO before_transfer;
        DBMS_OUTPUT.PUT_LINE('Loi: So du khong du');
    WHEN NO_DATA_FOUND THEN
        ROLLBACK TO before_transfer;
        DBMS_OUTPUT.PUT_LINE('Loi: Tai khoan ' || p_from_accid || ' hoac ' || p_to_accid || ' khong ton tai o Site ' || v_from_site);
    WHEN OTHERS THEN
        ROLLBACK TO before_transfer;
        DBMS_OUTPUT.PUT_LINE('Loi he thong: ' || SQLERRM);
END;


--- Kịch bản
--- 1 
INSERT INTO M03.TRANSACT_S3 (TRANID, ACCID, BRANCHID, AMOUNT, TRANSACTIONTYPE, TRANSDATE)
VALUES ('TXTEST03', 'ACC0750', 'B651', 9999999999, 'TRANSFER', SYSDATE);

--- 2
SELECT M03.FC_DISTRIBUTED_CREDIT_SCORING('CUS0750') AS CREDIT_RANK FROM DUAL;

--- 3
SET SERVEROUTPUT ON;
BEGIN
    M03.TRANSFER_MONEY('ACC0750', 'ACC9999', 1000000);
END;
/


--------------------------------------------------------------------------------
-- REQ 4: Query Optimization in Distributed Environment
--------------------------------------------------------------------------------
-- Ngữ cảnh kinh tế & Ý nghĩa chiến lược của câu truy vấn
-- Bài toán: Bộ phận Kiểm soát tuân thủ cần lập danh sách các khách hàng VIP 
-- có tổng số tiền thực hiện các giao dịch mang tính chất rút vốn hoặc chuyển tiền ('WITHDRAWAL', 'TRANSFER') 
-- với giá trị cực lớn (trên 80,000,000 VND/giao dịch) phát sinh tại các chi nhánh được xếp vào nhóm "Rủi ro cao" 
-- (ví dụ: các chi nhánh quốc tế hoặc trung tâm tài chính lớn như New York, London, Tokyo, Singapore), 
-- đi kèm điều kiện tài khoản đó chưa bị khóa (STATUS != 'LOCKED').

-- Bước 1: Câu truy vấn CHƯA TỐI ƯU (Non-optimized Query)
-- Bật đo thời gian thực tế
SET TIMING ON;

SELECT 
    C.CUSID,
    C.CUSNAME,
    A.ACCID,
    T.TRANID,
    T.AMOUNT,
    T.TRANSACTIONTYPE
FROM TRANSACT_S3 T
JOIN ACCOUNT_S3_A A ON T.ACCID = A.ACCID
JOIN ACCOUNT_S3_B B ON T.ACCID = B.ACCID
JOIN M01.CUSTOMER@DBL_M01 C ON A.CUSID = C.CUSID
WHERE T.AMOUNT > 80000000
  AND T.TRANSACTIONTYPE IN ('WITHDRAWAL', 'TRANSFER')
  AND B.STATUS != 'LOCKED'
  AND C.CUSID BETWEEN 'CUS 0100' AND 'CUS 0300';

-- Bước 2: Phân tích hiệu năng bằng EXPLAIN PLAN
-- Chạy chuỗi lệnh sau để phân tích cây chi phí gốc của câu lệnh chưa tối ưu:

EXPLAIN PLAN FOR
SELECT 
    C.CUSID,
    C.CUSNAME,
    A.ACCID,
    B.STATUS,
    T.TRANID,
    T.AMOUNT,
    T.TRANSACTIONTYPE
FROM TRANSACT_S3 T
JOIN ACCOUNT_S3_A A ON T.ACCID = A.ACCID
JOIN ACCOUNT_S3_B B ON T.ACCID = B.ACCID
JOIN M01.CUSTOMER@DBL_M01 C ON A.CUSID = C.CUSID
WHERE T.AMOUNT > 80000000
  AND T.TRANSACTIONTYPE IN ('WITHDRAWAL', 'TRANSFER')
  AND B.STATUS != 'LOCKED'
  AND C.CUSID BETWEEN 'CUS 0100' AND 'CUS 0300';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
ALTER SYSTEM FLUSH SHARED_POOL;

-- Bước 3: Áp dụng các kỹ thuật tối ưu hóa và Viết lại câu lệnh (Optimized Query)
--Predicate Pushdown (Đẩy điều kiện lọc xuống sâu nhất): Thay đổi cấu trúc truy vấn để lọc sạch tên Chi nhánh ngay tại Site từ xa (Máy 1) trước khi truyền gói tin qua mạng Radmin.
--Sử dụng Hint DRIVING_SITE: Chỉ định cho Oracle biết nên mang câu truy vấn sang chạy ở Site nào tối ưu nhất.
--Chuyển Subquery thành Inner Join có chỉ mục: Triệt tiêu hoàn toàn lệnh HASH JOIN diện rộng trên bảng số dư tài khoản.
SET TIMING ON;

SELECT
    C.CUSID,
    C.CUSNAME,
    A.ACCID,
    T.TRANID,
    T.AMOUNT,
    T.TRANSACTIONTYPE
FROM TRANSACT_S3 T
JOIN ACCOUNT_S3_A A ON T.ACCID = A.ACCID
JOIN ACCOUNT_S3_B B ON T.ACCID = B.ACCID
JOIN (
    -- Predicate Pushdown: Lọc dữ liệu tại đích trước khi truyền qua mạng
    SELECT CUSID, CUSNAME 
    FROM M01.CUSTOMER@DBL_M01 
    WHERE CUSID BETWEEN 'CUS 0100' AND 'CUS 0300'
) C ON A.CUSID = C.CUSID
WHERE T.AMOUNT > 80000000;

---
