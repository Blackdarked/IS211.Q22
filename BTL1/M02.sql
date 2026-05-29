CREATE TABLE BRANCH_F2(
    BRANCHID VARCHAR2(5) PRIMARY KEY,
    CITY VARCHAR2(50),
    ADDRESS VARCHAR2(100)
);
CREATE TABLE ACCOUNT_S2_A(
    ACCID VARCHAR2(10) PRIMARY KEY,
    CUSID VARCHAR2(10),
    BRANCHID VARCHAR2(5)
);
CREATE TABLE ACCOUNT_S2_B(
    ACCID VARCHAR2(10) PRIMARY KEY,
    BALANCE NUMBER,
    STATUS VARCHAR2(20),
    CREATED_AT DATE,
    DELETED_AT DATE
);
CREATE TABLE TRANSACT_S2(
    TRANID VARCHAR2(10) PRIMARY KEY,
    ACCID VARCHAR2(10),
    BRANCHID VARCHAR2(5),
    AMOUNT NUMBER,
    TRANSACTIONTYPE VARCHAR2(20),
    TRANSDATE DATE,
    CREATED_AT DATE,
    DELETED_AT DATE
);

COMMIT;

CREATE VIEW ACCOUNT_S2_VIEW AS
SELECT 
    A.ACCID,
    A.CUSID,
    A.BRANCHID,
    B.BALANCE,
    B.STATUS,
    B.CREATED_AT,
    B.DELETED_AT
FROM ACCOUNT_S2_A A
JOIN ACCOUNT_S2_B B
ON A.ACCID = B.ACCID;

COMMIT;



INSERT INTO BRANCH_F2 VALUES ('B07','Dong Nai', NULL);
INSERT INTO BRANCH_F2 VALUES ('B08','Thanh Hoa', NULL);
INSERT INTO BRANCH_F2 VALUES ('B09','Hue', NULL);

SELECT * FROM M02.BRANCH_F2

DROP DATABASE LINK DBL_M03;

SELECT * FROM dual@DBL_M01;


--------------------------------------------------------------------------------
-- REQ 2: BỔ SUNG DISTRIBUTED FUNCTION, integrity constraint, stored procedure (HÀM PHÂN TÁN CHẤM ĐIỂM TÍN DỤNG)
-- Ý nghĩa kinh tế: Phân tích lịch sử giao dịch liên Site để chấm điểm tín dụng khách hàng
--------------------------------------------------------------------------------

-- 1. Số dư không được âm
ALTER TABLE ACCOUNT_S2_B
ADD CONSTRAINT CHK_BALANCE_NON_NEGATIVE 
CHECK (BALANCE >= 0);

-- 2. Số tiền giao dịch phải dương
ALTER TABLE TRANSACT_S2
ADD CONSTRAINT CHK_AMOUNT_POSITIVE 
CHECK (AMOUNT > 0);

-- 3. Trạng thái tài khoản chỉ được trong danh sách cho phép
ALTER TABLE ACCOUNT_S2_B
ADD CONSTRAINT CHK_STATUS_VALID 
CHECK (STATUS IN ('ACTIVE', 'INACTIVE', 'LOCKED'));

-- 4. Loại giao dịch hợp lệ
ALTER TABLE TRANSACT_S2
ADD CONSTRAINT CHK_TRANSACTION_TYPE 
CHECK (TRANSACTIONTYPE IN ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER', 'PAYMENT', 'INTEREST', 'FEE'));

-- 5. DELETED_AT phải >= CREATED_AT
ALTER TABLE CUSTOMER_REP
ADD CONSTRAINT CHK_DELETE_AFTER_CREATE 
CHECK (DELETED_AT IS NULL OR DELETED_AT >= CREATED_AT);

-- 6. Trigger kiểm soát Business Rule liên Site: Số tiền rút/chuyển không được vượt quá số dư hiện tại
CREATE OR REPLACE TRIGGER TRG_CHECK_DISTRIBUTED_BUSINESS
BEFORE INSERT ON TRANSACT_S2
FOR EACH ROW
DECLARE
    v_current_balance NUMBER;
BEGIN
    IF :NEW.TRANSACTIONTYPE IN ('WITHDRAWAL', 'TRANSFER') THEN
        SELECT BALANCE INTO v_current_balance
        FROM ACCOUNT_S2_B
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
    FROM TRANSACT_S2 T 
    JOIN ACCOUNT_S2_A A ON T.ACCID = A.ACCID
    WHERE A.CUSID = p_cusid AND T.TRANSACTIONTYPE = 'DEPOSIT';

    -- 2. Quét dữ liệu từ mảnh từ xa thứ nhất (Ví dụ từ M01 quét sang M02)
    BEGIN
        EXECUTE IMMEDIATE 'SELECT NVL(SUM(T.AMOUNT), 0) FROM TRANSACT_S2@DBL_M02 T JOIN ACCOUNT_S2_A@DBL_M02 A ON T.ACCID = A.ACCID WHERE A.CUSID = :1 AND T.TRANSACTIONTYPE = ''DEPOSIT''' 
        INTO v_remote_deposit1 USING p_cusid;
    EXCEPTION WHEN OTHERS THEN v_remote_deposit1 := 0;
    END;

    -- 3. Quét dữ liệu từ mảnh từ xa thứ hai (Ví dụ từ M01 quét sang M03)
    BEGIN
        EXECUTE IMMEDIATE 'SELECT NVL(SUM(T.AMOUNT), 0) FROM TRANSACT_S3@DBL_M03 T JOIN ACCOUNT_S3_A@DBL_M03 A ON T.ACCID = A.ACCID WHERE A.CUSID = :1 AND T.TRANSACTIONTYPE = ''DEPOSIT''' 
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
    IF v_from_site = 2 THEN
        SELECT B.BALANCE, A.BRANCHID INTO v_from_balance, v_from_branchid
        FROM ACCOUNT_S2_B B JOIN ACCOUNT_S2_A A ON B.ACCID = A.ACCID
        WHERE B.ACCID = p_from_accid;
    ELSIF v_from_site = 1 THEN
        SELECT B.BALANCE, A.BRANCHID INTO v_from_balance, v_from_branchid
        FROM M01.ACCOUNT_S1_B@DBL_M01 B JOIN M01.ACCOUNT_S1_A@DBL_M01 A ON B.ACCID = A.ACCID
        WHERE B.ACCID = p_from_accid;
    ELSE
        SELECT B.BALANCE, A.BRANCHID INTO v_from_balance, v_from_branchid
        FROM M03.ACCOUNT_S3_B@DBL_M03 B JOIN M03.ACCOUNT_S3_A@DBL_M03 A ON B.ACCID = A.ACCID
        WHERE B.ACCID = p_from_accid;
    END IF;

    -- 5. Kiểm tra đủ tiền
    IF v_from_balance < p_amount THEN
        RAISE e_insufficient_balance;
    END IF;

    -- 6. Cập nhật trừ tiền
    IF v_from_site = 2 THEN
        UPDATE ACCOUNT_S2_B SET BALANCE = BALANCE - p_amount WHERE ACCID = p_from_accid;
    ELSIF v_from_site = 1 THEN
        UPDATE M01.ACCOUNT_S1_B@DBL_M01 SET BALANCE = BALANCE - p_amount WHERE ACCID = p_from_accid;
    ELSE
        UPDATE M03.ACCOUNT_S3_B@DBL_M03 SET BALANCE = BALANCE - p_amount WHERE ACCID = p_from_accid;
    END IF;

    -- 7. Cập nhật cộng tiền
    IF v_to_site = 2 THEN
        UPDATE ACCOUNT_S2_B SET BALANCE = BALANCE + p_amount WHERE ACCID = p_to_accid;
    ELSIF v_to_site = 1 THEN
        UPDATE M01.ACCOUNT_S1_B@DBL_M01 SET BALANCE = BALANCE + p_amount WHERE ACCID = p_to_accid;
    ELSE
        UPDATE M03.ACCOUNT_S3_B@DBL_M03 SET BALANCE = BALANCE + p_amount WHERE ACCID = p_to_accid;
    END IF;

    -- 8. Ghi log (Dùng v_from_branchid đã lấy được)
    INSERT INTO TRANSACT_S2 (TRANID, ACCID, BRANCHID, AMOUNT, TRANSACTIONTYPE, TRANSDATE)
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


----------------------------------------------------------------
-- REQ 1: 10 CÂU TRUY VẤN PHÂN TÁN CHIẾN LƯỢC KINH TẾ (MÁY 1)
----------------------------------------------------------------
-- Q1 [UNION ALL]: Tổng hợp báo cáo dòng tiền giao dịch lớn toàn hệ thống phục vụ phòng chống rửa tiền (> 90M)
SELECT 'NORTH_SITE' AS REGION, TRANID, ACCID, AMOUNT, TRANSDATE FROM M01.TRANSACT_S1@DBL_M01 WHERE AMOUNT > 90000000
UNION ALL
SELECT 'SOUTH_SITE' AS REGION, TRANID, ACCID, AMOUNT, TRANSDATE FROM M02.TRANSACT_S2 WHERE AMOUNT > 90000000
UNION ALL
SELECT 'CENTRAL_SITE' AS REGION, TRANID, ACCID, AMOUNT, TRANSDATE FROM M03.TRANSACT_S3@DBL_M03 WHERE AMOUNT > 90000000;

-- Q2 [INTERSECT]: Phát hiện tập khách hàng đa mục đích (Có tài khoản hoạt động song song ở cả khối Bắc và Nam)
SELECT CUSID FROM M02.ACCOUNT_S2_A
INTERSECT
SELECT CUSID FROM M01.ACCOUNT_S1_A@DBL_M01;

-- Q3 [MINUS]: Lọc ra danh sách khách hàng thuộc phân mảnh miền Bắc nhưng chưa phát sinh bất kỳ giao dịch nào tại miền Bắc
SELECT CUSID FROM M02.CUSTOMER_REP WHERE DELETED_AT IS NULL
MINUS
SELECT A.CUSID FROM M02.ACCOUNT_S2_A A JOIN M02.TRANSACT_S2 T ON A.ACCID = T.ACCID;

-- Q4 [DIVISION CHUẨN ĐẠI SỐ QUAN HỆ]: Tìm tài khoản "Kinh tế đặc biệt" có phát sinh giao dịch ở TẤT CẢ các chi nhánh thuộc bảng BRANCH_F1
SELECT A.ACCID, A.CUSID 
FROM M02.ACCOUNT_S2_A A
WHERE NOT EXISTS (
    SELECT B.BRANCHID FROM M02.BRANCH_F2 B
    WHERE NOT EXISTS (
        SELECT T.TRANID FROM M02.TRANSACT_S2 T 
        WHERE T.ACCID = A.ACCID AND T.BRANCHID = B.BRANCHID
    )
);

-- Q5 [GROUP BY + SUM]: Thống kê doanh số phí dịch vụ (FEE) thu được của từng chi nhánh trên toàn hệ thống để đánh giá KPI
SELECT BRANCHID, SUM(AMOUNT) AS TOTAL_FEE_REVENUE
FROM (
    SELECT BRANCHID, AMOUNT, TRANSACTIONTYPE FROM M02.TRANSACT_S2
    UNION ALL
    SELECT BRANCHID, AMOUNT, TRANSACTIONTYPE FROM M01.TRANSACT_S1@DBL_M01
) WHERE TRANSACTIONTYPE = 'FEE'
GROUP BY BRANCHID 
ORDER BY TOTAL_FEE_REVENUE DESC;

-- Q6 [HAVING + AVG]: Tìm các chi nhánh tiềm năng có số dư tài khoản trung bình của khách hàng thuộc phân khúc cao (> 60M)
SELECT BRANCHID, AVG(BALANCE) AS AVG_BRANCH_BALANCE
FROM (
    SELECT BRANCHID, BALANCE FROM M02.ACCOUNT_S2_VIEW
    UNION ALL
    SELECT BRANCHID, BALANCE FROM M01.ACCOUNT_S1_VIEW@DBL_M01
)
GROUP BY BRANCHID
HAVING AVG(BALANCE) > 60000000;

-- Q7 [ANALYTICAL COUNT]: Phân tích tần suất giao dịch trong ngày cao điểm để cảnh báo rủi ro vận hành hệ thống
SELECT ACCID, TRANSDATE, COUNT(TRANID) OVER(PARTITION BY ACCID) AS TX_DENSITY
FROM M02.TRANSACT_S2
WHERE AMOUNT > 50000000;

-- Q8 [DISTRIBUTED JOIN Phức tạp]: Truy xuất danh sách đen các tài khoản LOCKED kèm thông tin định danh cá nhân phục vụ thanh tra pháp lý
SELECT C.CUSNAME, C.PHONE, V.ACCID, V.BALANCE, V.STATUS
FROM M02.CUSTOMER_REP C
JOIN M01.ACCOUNT_S1_VIEW@DBL_M01 V ON C.CUSID = V.CUSID
WHERE V.STATUS = 'LOCKED';

-- Q9 [SUBQUERY PHÂN TÁN]: Tìm các tài khoản có số dư lớn hơn mức trung bình của toàn bộ hệ thống ngân hàng để tiếp thị sản phẩm đầu tư
SELECT ACCID, BALANCE, STATUS 
FROM M02.ACCOUNT_S2_VIEW
WHERE BALANCE > (
    SELECT AVG(BALANCE) FROM (
        SELECT BALANCE FROM M02.ACCOUNT_S2_VIEW
        UNION ALL
        SELECT BALANCE FROM M03.ACCOUNT_S3_VIEW@DBL_M03
    )
);

-- Q10 [TOP ROWS]: Trích xuất 5 giao dịch có giá trị dòng tiền luân chuyển lớn nhất hệ thống để báo cáo Thống đốc ngân hàng
SELECT * FROM (
    SELECT TRANID, ACCID, AMOUNT, TRANSACTIONTYPE FROM M02.TRANSACT_S2
    UNION ALL
    SELECT TRANID, ACCID, AMOUNT, TRANSACTIONTYPE FROM M01.TRANSACT_S1@DBL_M01
) ORDER BY AMOUNT DESC
FETCH FIRST 5 ROWS ONLY;

--💻 2. KỊCH BẢN KIỂM THỬ TẠI MÁY 2 (SITE 2)
--Lưu ý kỹ thuật: Do mã nguồn được thiết kế chạy đồng bộ, các cấu trúc bảng và view của Máy 2 sẽ ánh xạ tương ứng vào phân mảnh cục bộ của nó (TRANSACT_S2, ACCOUNT_S2_B). Nhóm bạn gọi trực tiếp từ Schema M02.

--📌 Case 1: Thử nghiệm Trigger tại phân mảnh Miền Nam
--Lệnh Test:

--SQL
-- Cố tình ép tài khoản thuộc Khối Nam (ACC0350) thực hiện giao dịch rút vượt hạn mức
INSERT INTO M02.TRANSACT_S2 (TRANID, ACCID, BRANCHID, AMOUNT, TRANSACTIONTYPE, TRANSDATE)
VALUES ('TXN TEST02', 'ACC 0350', 'B 301', 5000000000, 'WITHDRAWAL', SYSDATE);

SELECT * FROM ACCOUNT_S2_A WHERE ACCID ='ACC 0350'
SELECT * FROM TRANSACT_S2
-- ❌ KẾT QUẢ MONG ĐỢI: Hệ thống ném lỗi mã -20001 do Trigger tại địa bàn Máy 2 kiểm soát.
--📌 Case 2: Thử nghiệm Function tính điểm VIP từ Máy 2
--Lệnh Test:

--SQL
SELECT M02.FC_DISTRIBUTED_CREDIT_SCORING('CUS0350') AS CREDIT_RANK FROM DUAL;
--📌 Case 3: Thử nghiệm Procedure Chuyển tiền liên Site xuất phát từ Khối Nam
--Kịch bản: Tài khoản Khối Nam (ACC0350) chuyển khoản sang tài khoản Khối Miền Trung (ACC0750 nằm ở Máy 3).

--Lệnh Test:

--SQL
SET SERVEROUTPUT ON;
BEGIN
    M02.TRANSFER_MONEY('ACC 0350', 'ACC0730', 2000000);
END;

SELECT * 
FROM ACCOUNT_S2_A A JOIN ACCOUNT_S2_B B ON A.ACCID = B.ACCID 
WHERE A.ACCID = 'ACC 0350'
SELECT *
FROM M03.ACCOUNT_S3_A@DBL_M03 A JOIN M03.ACCOUNT_S3_B@DBL_M03 B ON A.ACCID = B.ACCID 
WHERE A.ACCID = 'ACC0730'
/
-- 🟢 KẾT QUẢ MONG ĐỢI: "Chuyển tiền thành công!". 
-- Hệ thống tự động nhảy vào khối lệnh ELSIF v_from_site = 2 và ELSE của v_to_site để thực thi cập nhật qua DB Link liên kết giữa các máy.
--💻 3. KỊCH BẢN KIỂM THỬ TẠI MÁY 3 (SITE 3)
--📌 Case 1: Thử nghiệm Trigger tại phân mảnh Miền Trung
--Lệnh Test:

--SQL
INSERT INTO M03.TRANSACT_S3 (TRANID, ACCID, BRANCHID, AMOUNT, TRANSACTIONTYPE, TRANSDATE)
VALUES ('TXTEST03', 'ACC0750', 'B651', 9999999999, 'TRANSFER', SYSDATE);
-- ❌ KẾT QUẢ MONG ĐỢI: Block cập nhật lập tức và quăng lỗi bảo vệ.
--📌 Case 2: Thử nghiệm Function đối soát tổng hợp từ Máy 3
--Lệnh Test:

--SQL
SELECT M03.FC_DISTRIBUTED_CREDIT_SCORING('CUS0750') AS CREDIT_RANK FROM DUAL;
--📌 Case 3: Thử nghiệm Quy trình Phục hồi dữ liệu lỗi của SP (Rollback Exception)
--Đây là phần cực kỳ quan trọng để quay video demo cho hội đồng, chứng minh tính toàn vẹn dữ liệu: Hệ thống sẽ tự động quay lui (ROLLBACK TO savepoint) khi phát hiện tài khoản thụ hưởng không tồn tại trên toàn mạng lưới phân tán.

--Kịch bản lỗi: Tài khoản Miền Trung ACC0750 thực hiện chuyển tiền sang một tài khoản ảo không tồn tại hệ thống (ACC9999).

--Lệnh Test:

SQL
SET SERVEROUTPUT ON;
BEGIN
    M03.TRANSFER_MONEY('ACC0750', 'ACC9999', 1000000);
END;
--/
--🔴 KẾT QUẢ TRÊN MÀN HÌNH (Ghi nhận Video):

--Màn hình console xuất thông báo: Truy van tai khoan nguon tai Site: 3

--Hệ thống chạy đến khối lệnh xử lý ngoại lệ và quăng thông báo an toàn: Loi: Tai khoan ACC0750 hoac ACC9999 khong ton tai o Site 3

--Nhóm thực hiện kiểm tra lại số dư của tài khoản ACC0750:

SQL
SELECT BALANCE FROM M03.ACCOUNT_S3_B WHERE ACCID = 'ACC0750';
--Số dư tài khoản giữ nguyên vẹn 100%, không bị trừ tiền oan. Điều này chứng minh lệnh ROLLBACK TO before_transfer đã hoạt động hoàn hảo bảo vệ tài sản hệ thống.


--------------------------------------------------------------------------------
-- REQ 3: KỊCH BẢN PHÂN TÍCH BẤT NHẤT DỮ LIỆU & ĐỀ XUẤT RETRY LOGIC (DEADLOCK)
--------------------------------------------------------------------------------
-- Mức Read Uncommitted (Chứng minh chính sách bảo vệ dòng tiền của Oracle)
-- Ý nghĩa chiến lược: Phòng quản lý rủi ro (Máy 1) thực hiện thẩm định tổng hạn mức dòng tiền thực tế (Số dư tài khoản + Thông tin chi nhánh) để cấp vốn, tránh việc đọc phải dữ liệu ảo đang trong quá trình xử lý lỗi ở Máy 2.
SET AUTOCOMMIT OFF;
-- [BƯỚC 1 - TẠI MÁY 1]: Phiên thẩm định bắt đầu truy vấn liên mảnh qua DB Link
SELECT C.CUSNAME, A.ACCID, B.BALANCE, BR.CITY
FROM M01.CUSTOMER C
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
JOIN M02.BRANCH_F2@DBL_M02 BR ON A.BRANCHID = BR.BRANCHID
WHERE A.ACCID = 'ACC 0301';
-- Kết quả ban đầu ghi nhận: Khách hàng có 50,000,000 VND tại chi nhánh Hồ Chí Minh.
-- [BƯỚC 2 - TẠI MÁY 2]: Local thực hiện quy trình giải ngân tiền vay nhưng CHƯA COMMIT
UPDATE ACCOUNT_S2_B SET BALANCE = BALANCE + 500000000 WHERE ACCID = 'ACC 0301';

-- [BƯỚC 3 - TẠI MÁY 1]: Máy 1 thực hiện SELECT lại câu lệnh phức tạp trên một lần nữa
SELECT C.CUSNAME, A.ACCID, B.BALANCE, BR.CITY
FROM M01.CUSTOMER C
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
JOIN M02.BRANCH_F2@DBL_M02 BR ON A.BRANCHID = BR.BRANCHID
WHERE A.ACCID = 'ACC 0301';
-- 📝 Kết quả VẪN LÀ: 50,000,000 VND. 
-- -> Giải thích: Oracle ngăn chặn Dirty Read để bảo vệ bộ phận thẩm định khỏi các quyết định cấp vốn sai lệch dựa trên dòng tiền ảo chưa commit của Máy 2.

-- [BƯỚC 4 - TẠI MÁY 2]: Hoàn tác dữ liệu thử nghiệm
ROLLBACK;



-- Mức Read Committed (Minh họa rủi ro Non-Repeatable Read trong đối soát)
-- Ý nghĩa chiến lược: Kiểm toán viên (Máy 1) đang tính toán tỷ trọng dư nợ của các chi nhánh miền Nam. Nếu để ở mức mặc định này, dữ liệu sẽ bị lệch nếu khách hàng thanh toán nợ ngay trong lúc kiểm toán đang chạy lệnh.


-- [BƯỚC 1 - TẠI MÁY 1]: Kiểm toán chạy lệnh trích xuất báo cáo tỷ trọng lần 1
SELECT BR.BRANCHNAME, SUM(B.BALANCE) AS TOTAL_DEPOSIT, AVG(B.BALANCE) AS AVG_DEPOSIT
FROM M02.ACCOUNT_S2_A@DBL_M02 A
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
JOIN M02.BRANCH_F2@DBL_M02 BR ON A.BRANCHID = BR.BRANCHID
GROUP BY BR.BRANCHNAME;
-- 📝 Ghi nhận số liệu lần 1 của chi nhánh X (Ví dụ: Tổng tiền = 10 tỷ).

-- [BƯỚC 2 - TẠI MÁY 2]: Local Máy 2 thực hiện xử lý một lô giao dịch tất toán nợ lớn và COMMIT
UPDATE ACCOUNT_S2_B SET BALANCE = BALANCE - 20000000 WHERE ACCID IN (SELECT ACCID FROM ACCOUNT_S2_A WHERE BRANCHID = 'B 303');
COMMIT;

-- [BƯỚC 3 - TẠI MÁY 1]: Vẫn trong phiên làm việc đó, Máy 1 chạy lại câu lệnh GROUP BY kết nhiều bảng trên
SELECT BR.BRANCHNAME, SUM(B.BALANCE) AS TOTAL_DEPOSIT, AVG(B.BALANCE) AS AVG_DEPOSIT
FROM M02.ACCOUNT_S2_A@DBL_M02 A
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
JOIN M02.BRANCH_F2@DBL_M02 BR ON A.BRANCHID = BR.BRANCHID
GROUP BY BR.BRANCHNAME;
-- ❌ HẬU QUẢ: Số liệu tổng tiền sụt xuống còn 8 tỷ. Báo cáo kiểm toán bị mất tính nhất quán (Non-Repeatable Read).
COMMIT;

-- Mức Repeatable Read (Đóng băng dữ liệu bằng giải pháp Khóa độc quyền đa bảng)
-- Ý nghĩa chiến lược: Để đóng băng toàn bộ thông tin dòng tiền và thông tin định danh của một nhóm tài khoản phục vụ thanh tra, kế toán dùng kỹ thuật khóa bi quan liên bảng để ngăn chặn Máy 2 sửa đổi bất kỳ thông tin nào liên quan.
-- [BƯỚC 1 - TẠI MÁY 1]: Máy 1 thực hiện truy vấn và khóa toàn bộ cấu trúc liên đới qua DB Link
SELECT C.CUSNAME, A.ACCID, B.BALANCE
FROM M01.CUSTOMER C
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
WHERE B.BALANCE > 80000000
FOR UPDATE OF B.BALANCE; -- Khóa cứng toàn bộ các dòng số dư thỏa mãn điều kiện tại Máy 2

-- [BƯỚC 2 - TẠI MÁY 2]: Máy 2 cố tình cập nhật số dư của một tài khoản trong nhóm trên tại Local
UPDATE ACCOUNT_S2_B SET BALANCE = BALANCE - 1000000 WHERE ACCID = 'ACC 0305';
-- 💥 HIỆN TƯỢNG: Màn hình Máy 2 bị TREO HOÀN TOÀN (Lock Wait) vì dòng này đã bị Máy 1 chiếm giữ khóa từ xa.

-- [BƯỚC 3 - TẠI MÁY 1]: Máy 1 hoàn tất phiên thanh tra
COMMIT; -- Máy 2 lập tức hết treo và thực thi lệnh update thành công.

-- Mức Serializable (Bảo vệ Snapshot giao dịch thông minh)
-- Ý nghĩa chiến lược: Đảm bảo cho các báo cáo phân tích chiến lược kinh tế (BI) được chạy trên một "ảnh chụp" tĩnh hoàn hảo của toàn bộ mạng lưới phân tán, không bị ảnh hưởng bởi tương tranh.
-- [BƯỚC 1 - TẠI MÁY 1]: Kích hoạt mức bảo vệ cao nhất cho phiên làm việc
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- Lệnh phân tích tổng tài sản phân tán của khách hàng VIP
SELECT C.CUSNAME, SUM(B.BALANCE) AS TOTAL_ASSETS, MAX(B.BALANCE) AS MAX_ASSETS
FROM M01.CUSTOMER C
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
WHERE CUS_NAME = 'Khach hang 356'
GROUP BY C.CUSNAME;

-- [BƯỚC 2 - TẠI MÁY 2]: Local thực hiện hàng loạt giao dịch nạp tiền tăng số dư tài khoản và COMMIT
UPDATE ACCOUNT_S2_B SET BALANCE = BALANCE + 10000000 WHERE ACCID = 'ACC 0521';
COMMIT;

-- [BƯỚC 3 - TẠI MÁY 1]: Máy 1 chạy lại câu lệnh tổng tài sản phức tạp trên
SELECT A.ACCID, C.CUSNAME, SUM(B.BALANCE) AS TOTAL_ASSETS, MAX(B.BALANCE) AS MAX_ASSETS
FROM M01.CUSTOMER@DBL_M01 C
JOIN ACCOUNT_S2_A A ON C.CUSID = A.CUSID
JOIN ACCOUNT_S2_B B ON A.ACCID = B.ACCID
WHERE C.CUSNAME = 'Khach hang 356'
GROUP BY C.CUSNAME, A.ACCID;
-- 📝 Kết quả VẪN GIỮ NGUYÊN NHẤT QUÁN nhờ Oracle lấy dữ liệu từ Undo Segment phục vụ ảnh chụp Snapshot.

-- [BƯỚC 4 - TẠI MÁY 1]: Gây lỗi xung đột phiên bản (First-Committer-Wins)
UPDATE M02.ACCOUNT_S2_B@DBL_M02 SET BALANCE = BALANCE - 200000 WHERE ACCID = 'ACC 0356';
-- ❌ HỆ THỐNG QUĂNG LỖI BẢO VỆ: ORA-08177: can't serialize access for this transaction.
ROLLBACK;

-- Trường hợp 1: LOST UPDATE: 
--Ngữ cảnh Chiến lược Kinh tế
--Hệ thống lõi ngân hàng chạy hai tiến trình tự động song song tác động vào cùng một phân khúc tệp khách hàng VIP:

--Tiến trình 1 (Máy 1 - Session A): Hệ thống quét tự động cuối kỳ để thu phí quản lý tài khoản của các khách hàng VIP thuộc chi nhánh Phía Nam (BRANCH_F2).

--Tiến trình 2 (Máy 2 - Session B): Khách hàng VIP thực hiện giao dịch rút tiền mặt giá trị lớn tại quầy Local của chi nhánh Phía Nam.

--[Thời điểm T1 – Máy 1] (Session A) bắt đầu quét kiểm toán qua mạng Radmin

SELECT C.CUSNAME, A.ACCID, B.BALANCE, BR.CITY, COUNT(T.TRANID) AS TOTAL_TX
FROM M01.CUSTOMER C
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
JOIN M02.BRANCH_F2@DBL_M02 BR ON A.BRANCHID = BR.BRANCHID
LEFT JOIN M02.TRANSACT_S2@DBL_M02 T ON A.ACCID = T.ACCID
WHERE A.ACCID = 'ACC 0310'
GROUP BY C.CUSNAME, A.ACCID, B.BALANCE, BR.CITY;

--[Thời điểm T2 – Máy 2] (Session B) thực hiện giao dịch tại quầy Local
SELECT C.CUSNAME, A.ACCID, B.BALANCE, BR.CITY, COUNT(T.TRANID) AS TOTAL_TX
FROM M02.CUSTOMER_REP C
JOIN ACCOUNT_S2_A A ON C.CUSID = A.CUSID
JOIN ACCOUNT_S2_B B ON A.ACCID = B.ACCID
JOIN BRANCH_F2 BR ON A.BRANCHID = BR.BRANCHID
LEFT JOIN TRANSACT_S2 T ON A.ACCID = T.ACCID
WHERE A.ACCID = 'ACC 0310'
GROUP BY C.CUSNAME, A.ACCID, B.BALANCE, BR.CITY;
-- 📝 Hệ thống Máy 2 cũng đọc ra số dư thực tế hiện tại là: 10,000,000 VND.

--[Thời điểm T3 – Máy 1] (Session A) thực hiện lệnh Trừ phí dịch vụ
UPDATE M02.ACCOUNT_S2_B@DBL_M02 
SET BALANCE = 98000000 
WHERE ACCID = 'ACC 0310';
-- Lệnh thực thi thành công: "1 row updated" (Nhưng chưa bấm COMMIT).
--[Thời điểm T4 – Máy 2] (Session B) thực hiện lệnh Rút tiền mặt tại quầy
UPDATE ACCOUNT_S2_B 
SET BALANCE = 70000000 
WHERE ACCID = 'ACC 0310';
-- 💥 HIỆN TƯỢNG TRÊN VIDEO: Cửa sổ Máy 2 lập tức bị TREO CỨNG (Lock Wait). 
-- Giải thích: Vì dòng dữ liệu của tài khoản này trên bảng vật lý đã bị Máy 1 chiếm giữ khóa độc quyền (X-Lock) ở thời điểm T3 qua liên kết DB Link. 

--[Thời điểm T5 – Máy 1] (Session A) kết thúc quy trình kiểm toán
INSERT INTO M02.TRANSACT_S2@DBL_M02 (TRANID, ACCID, AMOUNT, TRANSACTIONTYPE, TRANSDATE)
VALUES ('FEE' || TO_CHAR(SYSTIMESTAMP,'YYYYMMDDHH24MISS'), 'ACC 0310', 2000000, 'FEE', SYSDATE);

COMMIT;
--[Thời điểm T6 – Máy 2] (Session B) tự động chạy tiếp khi khóa được giải phóng
INSERT INTO TRANSACT_S2 (TRANID, ACCID, AMOUNT, TRANSACTIONTYPE, TRANSDATE)
VALUES ('WTH' || TO_CHAR(SYSTIMESTAMP,'YYYYMMDDHH24MISS'), 'ACC 0310', 30000000, 'WITHDRAWAL', SYSDATE);

COMMIT;

--❌ Hậu quả Bất nhất dữ liệu (Lost Update)Tài khoản thực tế bị khấu trừ 2 khoản tiền tổng cộng là 32M ($2M + 30M$). Số dư đúng logic phải là $68,000,000$ VND.Tuy nhiên, do Máy 2 lưu dữ liệu dựa trên Snapshot cũ (70M), nó đã ghi đè hoàn toàn và xóa sạch kết quả trừ tiền 98M của Máy 1. Cơ sở dữ liệu hiện tại lưu sai thành $70,000,000$ VND $\rightarrow$ Ngân hàng thất thoát quỹ tiền thu phí dịch vụ.


-- Trường hợp 2: Non-Repeatable Read phân tán trong quy trình Xét duyệt giải ngân hạn mức tín dụng
-- Rủi ro kinh tế: Hệ thống phê duyệt nhầm hạn mức cho vay vượt quá năng lực tài chính thực tế của khách hàng do dữ liệu nền bị thay đổi liên tục trong phiên xử lý.

-- [BƯỚC 1 - MÁY 1]: Ban giám đốc chạy lệnh đánh giá tổng số dư khả dụng của khách hàng phục vụ cấp hạn mức tín dụng
SELECT C.CUSNAME, SUM(B.BALANCE) AS TOTAL_LIQUIDITY
FROM M01.CUSTOMER C 
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
WHERE C.CUSID = 'CUS0350' GROUP BY C.CUSNAME;
-- 📝 Kết quả ghi nhận tổng khả dụng: 200,000,000 VND -> Đủ điều kiện phê duyệt gói vay 1 tỷ.

-- [BƯỚC 2 - MÁY 2]: Ngay trong lúc ban giám đốc đang thảo luận, khách hàng thực hiện lệnh rút phần lớn tiền tại Local Máy 2
UPDATE ACCOUNT_S2_B SET BALANCE = 5000000 WHERE ACCID IN (SELECT ACCID FROM ACCOUNT_S2_A WHERE CUSID = 'CUS 0356');
COMMIT;

-- [BƯỚC 3 - MÁY 1]: Trước khi nhấn nút "Phê duyệt" cuối cùng, hệ thống chạy lại lệnh kiểm tra đối soát tự động
SELECT C.CUSNAME, SUM(B.BALANCE) AS TOTAL_LIQUIDITY
FROM M01.CUSTOMER C 
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
WHERE C.CUSID = 'CUS0350' GROUP BY C.CUSNAME;
-- ❌ HẬU QUẢ: Tổng khả dụng sụt giảm nghiêm trọng xuống chỉ còn 5,000,000 VND. Nếu quy trình phê duyệt tự động không kiểm soát mức cô lập, ngân hàng sẽ dính rủi ro nợ xấu nghiêm trọng do cấp sai hạn mức tín dụng dựa trên số liệu không nhất quán.
COMMIT;


-- 3. Trường hợp 3: Phantom Read phân tán trong quy trình Quản lý rủi ro nợ xấu nhóm 5 (Tài khoản bị khóa)
-- Rủi ro kinh tế: Số liệu phân tích trích lập dự phòng rủi ro nợ xấu của ngân hàng bị sai lệch hoàn toàn do xuất hiện các bản ghi "bóng ma" nhảy vào giữa phiên tổng hợp báo cáo.

-- [BƯỚC 1 - MÁY 1]: Phòng quản lý rủi ro đếm số lượng khách hàng VIP có tài khoản bị LOCKED để trích lập quỹ dự phòng nợ xấu
SELECT COUNT(DISTINCT C.CUSID) AS LOCKED_VIP_COUNT
FROM M01.CUSTOMER C
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
WHERE B.STATUS = 'LOCKED' AND B.BALANCE > 50000000;

-- [BƯỚC 2 - MÁY 2]: Hệ thống xử lý nợ tự động tại Máy 2 thực hiện quét và chuyển trạng thái khóa thêm các tài khoản vi phạm mới
INSERT INTO ACCOUNT_S2_B (ACCID, BALANCE, STATUS) VALUES ('ACC 1002', 90000000, 'LOCKED');
INSERT INTO ACCOUNT_S2_A (ACCID, CUSID, BRANCHID) VALUES ('ACC 1002', 'CUS 0356', 'B 301');
COMMIT;

-- [BƯỚC 3 - MÁY 1]: Máy 1 kết xuất lại báo cáo để in nộp ngân hàng trung ương
SELECT COUNT(DISTINCT C.CUSID) AS LOCKED_VIP_COUNT
FROM M01.CUSTOMER C
JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
JOIN M02.ACCOUNT_S2_B@DBL_M02 B ON A.ACCID = B.ACCID
WHERE B.STATUS = 'LOCKED' AND B.BALANCE > 50000000;
COMMIT;

-- Trường hợp 4: Distributed Deadlock 
--Quy trình thanh toán bù trừ liên vùng (Clearing Settlement) diễn ra đồng thời giữa hai Khối kinh tế thông qua tài khoản trung chuyển của hai doanh nghiệp đối tác lớn: ACC 0350 (Doanh nghiệp đặt tại Khối miền Nam - Máy 2) và ACC 0150 (Doanh nghiệp đặt tại Khối miền Bắc - Máy 1).
-- hai tiến trình đều phải quét qua hệ thống danh mục 4 bảng để kiểm tra tính hợp lệ trước khi điều phối dòng tiền.
--[Thời điểm T1 – Máy 1] (Session A) Khối miền Bắc chiếm giữ Khóa dòng tại Khối miền Nam
UPDATE M02.ACCOUNT_S2_B@DBL_M02 
SET BALANCE = BALANCE + 100000000 
WHERE ACCID = (
    SELECT A.ACCID 
    FROM M01.CUSTOMER C
    JOIN M02.ACCOUNT_S2_A@DBL_M02 A ON C.CUSID = A.CUSID
    JOIN M02.BRANCH_F2@DBL_M02 BR ON A.BRANCHID = BR.BRANCHID
    WHERE A.ACCID = 'ACC 0350' AND BR.CITY = 'Hồ Chí Minh'
);
-- 🔐 KẾT QUẢ: Lệnh chạy thành công. Máy 1 chính thức chiếm giữ khóa dòng dữ liệu của tài khoản ACC 0350 tại Máy 2.

--[Thời điểm T2 – Máy 2] (Session B) Khối miền Nam chiếm giữ Khóa dòng tại Khối miền Bắc
UPDATE M01.ACCOUNT_S1_B@DBL_M01 
SET BALANCE = BALANCE - 500000 
WHERE ACCID = (
    SELECT A.ACCID 
    FROM M02.CUSTOMER_REP C
    JOIN M01.ACCOUNT_S1_A@DBL_M01 A ON C.CUSID = A.CUSID
    JOIN M01.BRANCH_F1@DBL_M01 BR ON A.BRANCHID = BR.BRANCHID
    WHERE A.ACCID = 'ACC 0151' AND BR.BRANCHNAME = 'Hà Nội'
);

SELECT *
FROM M02.CUSTOMER_REP C
    JOIN M01.ACCOUNT_S1_A@DBL_M01 A ON C.CUSID = A.CUSID
    JOIN M01.BRANCH_F1@DBL_M01 BR ON A.BRANCHID = BR.BRANCHID
    WHERE A.ACCID = 'ACC 0150'
-- 🔐 KẾT QUẢ: Lệnh chạy thành công tại Local Máy 1. Máy 2 chính thức chiếm giữ khóa dòng dữ liệu của tài khoản ACC 0150 tại Máy 1.

--[Thời điểm T3 – Máy 1] (Session A) cố gắng can thiệp vào tài khoản đang bị Máy 2 khóa
UPDATE M01.ACCOUNT_S1_B 
SET BALANCE = BALANCE - 100000 
WHERE ACCID = (
    SELECT A.ACCID 
    FROM M01.CUSTOMER C
    JOIN M01.ACCOUNT_S1_A A ON C.CUSID = A.CUSID
    JOIN M01.BRANCH_F1 BR ON A.BRANCHID = BR.BRANCHID
    WHERE A.ACCID = 'ACC 0150'
);
-- 💥 HIỆN TƯỢNG: Cửa sổ Máy 1 ngay lập tức bị TREO (Lock Wait).
-- Giải thích: Vì tài khoản ACC 0150 đang bị Máy 2 chiếm giữ độc quyền khóa từ mốc thời gian T2.

--[Thời điểm T4 – Máy 2] (Session B) can thiệp ngược lại tạo thành vòng lặp nghẽn mạch

--❌ Hậu quả Hệ thống (Distributed Deadlock)
--Ngay khi Máy 2 nhấn thực thi lệnh ở thời điểm T4, đồ thị tài nguyên của hệ thống xác định vòng lặp chết nghẽn phân tán hoàn chỉnh: Máy 1 giữ khóa Máy 2 và đợi Máy 2; Máy 2 giữ khóa Máy 1 và đợi Máy 1.

--Cơ chế tự động phòng vệ của Oracle RDBMS lập tức can thiệp để giải cứu Core Banking khỏi sập cục bộ. Hệ thống chủ động chọn hy sinh một bên, giải phóng toàn bộ khóa và quăng lỗi báo tử trực tiếp trên màn hình:

--------------------------------------------------------------------------------
-- REQ 5: Indexing in Oracle
--------------------------------------------------------------------------------

--5. Composite Index (Chỉ mục tổ hợp)Bản chất: Là chỉ mục B-Tree được xây dựng bằng cách gộp nhiều cột thường xuyên xuất hiện đồng thời trong mệnh đề WHERE lại với nhau. Giúp Oracle kiểm tra đa hướng và khoanh vùng tập dữ liệu đích ngay tại tầng mục lục mà không cần tốn chi phí trộn nhiều index đơn lẻ.

-- Biên kịch: Báo cáo kiểm toán luân chuyển vốn giá trị lớn. Bộ phận kiểm toán nội bộ cần lọc ngay lập tức các giao dịch rút tiền mặt ('WITHDRAWAL') có giá trị dòng tiền cao (trên 5.000.000 VNĐ) của một tài khoản VIP xác định mà không muốn câu lệnh bị ảnh hưởng bởi sự phân phối lệch của trường thời gian ngẫu nhiên.
ALTER SYSTEM FLUSH SHARED_POOL;

EXPLAIN PLAN FOR
SELECT T.TRANID,
       T.AMOUNT,
       T.TRANSACTIONTYPE,
       A.ACCID,
       C.CUSNAME,
       BR.BRANCHNAME
FROM M02.TRANSACT_S2 T
JOIN M02.ACCOUNT_S2_A A 
    ON T.ACCID = A.ACCID
JOIN M02.CUSTOMER_REP C 
    ON A.CUSID = C.CUSID
JOIN M01.BRANCH_F1@DBL_M01 BR 
    ON T.BRANCHID = BR.BRANCHID
WHERE T.ACCID = 'ACC 0350'
  AND T.TRANSACTIONTYPE = 'WITHDRAWAL'
  AND T.AMOUNT > 5000000;
  
SELECT * 
FROM TABLE(DBMS_XPLAN.DISPLAY);
-- Tạo Composite Index gộp 3 cột điều kiện lọc phối hợp từ độ chọn lọc cao đến thấp
CREATE INDEX M02.IDX_T_COMP_ACC_TYPE_AMT ON M02.TRANSACT_S2 (ACCID, TRANSACTIONTYPE, AMOUNT);
DROP INDEX M02.IDX_T_COMP_ACC_TYPE_AMT;
DROP INDEX IDX_TRANS_TYPE_BITMAP
ON TRANSACT_S2 (TRANSACTIONTYPE);

--6. Bitmap Index (Chỉ mục bản đồ Bit)

EXPLAIN PLAN FOR
SELECT 
    T.TRANID,
    T.AMOUNT,
    T.TRANSACTIONTYPE,
    A.ACCID,
    A.CUSID,
    B.STATUS,
    BR.BRANCHNAME
FROM TRANSACT_S2 T
JOIN ACCOUNT_S2_A A ON T.ACCID = A.ACCID
JOIN ACCOUNT_S2_B B ON A.ACCID = B.ACCID
JOIN M01.BRANCH_F1@DBL_M01 BR ON T.BRANCHID = BR.BRANCHID
WHERE T.TRANSACTIONTYPE = 'TRANSFER'
  AND B.STATUS = 'LOCKED'
  AND T.AMOUNT > 50000000;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
-- Tạo Bitmap Index trên cột STATUS (Cột có độ chọn lọc thấp, ít giá trị nhưng lặp lại hàng triệu lần)
CREATE BITMAP INDEX M02.IDX_A_STATUS_BITMAP ON M02.ACCOUNT_S2_B (STATUS);

DROP INDEX M02.IDX_A_STATUS_BITMAP;

ALTER SYSTEM FLUSH SHARED_POOL;


