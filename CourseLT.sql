USE master
GO

IF DB_ID('CourseLT') IS NOT NULL
    DROP DATABASE CourseLT
GO

CREATE DATABASE CourseLT
GO

USE CourseLT
GO

CREATE SCHEMA Study
GO

CREATE SCHEMA Archive
GO

CREATE SEQUENCE Study.SeqCourse AS INT
    START WITH 1
    INCREMENT BY 1;

CREATE TABLE Study.Course(
    CourseId INT PRIMARY KEY DEFAULT NEXT VALUE FOR Study.SeqCourse,
    CourseName VARCHAR(255) NOT NULL,
    Price NUMERIC(9, 2) NOT NULL,
    CONSTRAINT CK_Price CHECK ( Price >= 0 )
);

CREATE SEQUENCE Study.SeqModule AS INT
    START WITH 1
    INCREMENT BY 1;

CREATE TABLE Study.Module(
    ModuleId INT PRIMARY KEY DEFAULT NEXT VALUE FOR Study.SeqModule,
    ModuleName VARCHAR(255) NOT NULL,
    ModuleDescription VARCHAR(255) NOT NULL,
    CourseId INT NOT NULL REFERENCES Study.Course(CourseId),
    CONSTRAINT UK_ModuleName UNIQUE (CourseId, ModuleName)
);

CREATE SEQUENCE Study.SeqStudent AS INT START WITH 1 INCREMENT BY 1;

CREATE TABLE Study.Student(
    StudentId INT PRIMARY KEY DEFAULT NEXT VALUE FOR Study.SeqStudent,
    FirstName VARCHAR(50) NOT NULL,
    LastName VARCHAR(50) NOT NULL,
    MiddleName VARCHAR(50) NOT NULL,
    BirthDate DATE NOT NULL,
    RegistrationDate DATE NOT NULL DEFAULT GETDATE(),
    Phone VARCHAR(15) NOT NULL UNIQUE,
    Email VARCHAR(50) NOT NULL UNIQUE,
    Gender VARCHAR(15) NOT NULL,
    CONSTRAINT CK_Gender CHECK (Gender IN (N'Мужчина', N'Женщина')),
    CONSTRAINT CK_BirthDate CHECK (
        IIF(DATEADD(year, -DATEDIFF(year, BirthDate, GETDATE()), GETDATE()) < BirthDate,
        DATEDIFF(year, BirthDate, GETDATE())-1,
        DATEDIFF(year, BirthDate, GETDATE())) >= 18
    )
)

CREATE SEQUENCE Study.SeqSpecialization AS INT START WITH 1 INCREMENT BY 1;

CREATE TABLE Study.Specialization(
    SpecializationId INT PRIMARY KEY DEFAULT NEXT VALUE FOR Study.SeqSpecialization,
    SpecializationName VARCHAR(255) NOT NULL UNIQUE,
    Duration SMALLINT NOT NULL,
    Price NUMERIC(9, 2) NOT NULL,
    CONSTRAINT CK_Duration CHECK (Duration BETWEEN 2 AND 4)
);

CREATE SEQUENCE Study.SeqSemester AS INT START WITH 1 INCREMENT BY 1;

CREATE TABLE Study.Semester(
    SemesterId INT PRIMARY KEY DEFAULT NEXT VALUE FOR Study.SeqSemester,
    SemesterNumber SMALLINT NOT NULL,
    SpecializationId INT NOT NULL REFERENCES Study.Specialization(SpecializationId)
);

CREATE TABLE Study.Curriculum(
    CourseId INT REFERENCES Study.Course(CourseId),
    SemesterId INT REFERENCES Study.Semester(SemesterId),
    CONSTRAINT PK_Curriculum PRIMARY KEY (CourseId, SemesterId)
);

CREATE SEQUENCE Study.SeqAcademicGroup AS INT START WITH 1 INCREMENT BY 1;

CREATE TABLE Study.AcademicGroup(
    GroupId INT PRIMARY KEY DEFAULT NEXT VALUE FOR Study.SeqAcademicGroup,
    GroupName VARCHAR(50) NOT NULL UNIQUE,
    Limit SMALLINT NOT NULL,
    SpecializationId INT NOT NULL REFERENCES Study.Specialization(SpecializationId),
    SemesterId INT NULL REFERENCES Study.Semester(SemesterId)
);

CREATE TABLE Study.StudentGroup(
    StudentId INT REFERENCES Study.Student(StudentId),
    GroupId INT REFERENCES Study.AcademicGroup(GroupId),
    CONSTRAINT PK_StudentGroup PRIMARY KEY (StudentId, GroupId)
);

-- Архивные таблицы
-- Архив курсов
CREATE TABLE Archive.CourseArchive(
    CourseId INT NOT NULL,
    CourseName VARCHAR(255) NOT NULL,
    Price NUMERIC(9, 2) NOT NULL
);

-- Архив модулей
CREATE TABLE Archive.ModuleArchive(
    ModuleId INT NOT NULL,
    ModuleName VARCHAR(255) NOT NULL,
    ModuleDescription VARCHAR(255) NOT NULL,
    CourseId INT NOT NULL
);

GO
CREATE OR ALTER FUNCTION Study.count_members(@GroupId INT) RETURNS INT AS
    BEGIN
        DECLARE @Result INT = (SELECT COUNT(GroupId) FROM Study.StudentGroup WHERE GroupId = @GroupId);
        RETURN @Result;
    END
GO

CREATE TRIGGER Study.check_group_limit ON Study.StudentGroup AFTER INSERT AS
    BEGIN
        IF EXISTS(
            SELECT * FROM inserted AS I
                JOIN Study.AcademicGroup AS AG ON I.GroupId = AG.GroupId AND AG.Limit < Study.count_members(I.GroupId)
            )
        THROW 51001, N'Превышено максимльное число студентов в группе!', 10;
    END

GO

CREATE VIEW Study.GroupInfo AS
    SELECT
           AG.GroupId,
           AG.GroupName,
           CAST(ISNULL(Se.SemesterNumber, N'Обучение не начато') AS VARCHAR(25)) AS Semester,
           S.SpecializationName,
           S.Price,
           AG.Limit AS max_members,
           Study.count_members(AG.GroupId) AS members
    FROM Study.AcademicGroup AS AG
        JOIN Study.Specialization AS S ON AG.SpecializationId = S.SpecializationId
        JOIN Study.Semester AS Se ON S.SpecializationId = Se.SpecializationId
GO

CREATE OR ALTER PROCEDURE Study.new_specialization
    @Name VARCHAR(255),
    @Price NUMERIC(9, 2),
    @Duration SMALLINT
AS
    BEGIN
        DECLARE
            @Counter INT = 1,
            @SpecializationId INT = NEXT VALUE FOR Study.SeqSpecialization;
        INSERT INTO Study.Specialization(SpecializationId, SpecializationName, Price, Duration) VALUES (@SpecializationId, @Name, @Price, @Duration);
        WHILE @Counter <= @Duration
        BEGIN
            INSERT INTO Study.Semester(SemesterNumber, SpecializationId) VALUES (@Counter, @SpecializationId);
            SET @Counter += 1;
        END
    END

GO
CREATE OR ALTER FUNCTION Study.sum_course_price(@SpecializationId INT) RETURNS NUMERIC(9, 2) AS
    BEGIN
        DECLARE @SumPrice NUMERIC(9, 2) = (
            SELECT SUM(C.Price) FROM Study.Course AS C
                JOIN Study.Curriculum AS Cu ON C.CourseId = Cu.CourseId
                JOIN Study.Semester AS S ON S.SemesterId = Cu.SemesterId AND S.SpecializationId = @SpecializationId
            );
        RETURN @SumPrice;
    END
GO
CREATE VIEW Study.AllCourses WITH SCHEMABINDING AS
    SELECT C.CourseId, C.CourseName, C.Price FROM Study.Course AS C
    UNION
    SELECT CA.CourseId, CA.CourseName, CA.Price FROM Archive.CourseArchive AS CA;
GO

CREATE OR ALTER FUNCTION Study.check_course_in_archive(@Name VARCHAR(255)) RETURNS BIT AS
    BEGIN
        IF @Name IN (SELECT CourseName FROM Archive.CourseArchive)
            RETURN 1;
        RETURN 0;
    END

GO

-- Проверка наличия одноименного курса в архиве, выполняемая при добавлении и переименовании курса
CREATE OR ALTER TRIGGER Study.check_course ON Study.Course AFTER INSERT, UPDATE AS
    BEGIN
        IF UPDATE(CourseName)
        BEGIN
            IF EXISTS(
                SELECT * FROM inserted AS I
                    WHERE Study.check_course_in_archive(I.CourseName) = 1
                )
            THROW 51002, N'Курс с заданным именем присутствует в архиве!', 10;
        END
    END
GO

-- Удаление и архивирование курса со всеми его модулями
CREATE TRIGGER Study.archiving_course ON Study.Course INSTEAD OF DELETE AS
    BEGIN
	    DELETE FROM Study.Module
		OUTPUT
                deleted.ModuleId,
                deleted.ModuleName,
                deleted.ModuleDescription,
                deleted.CourseId
        INTO Archive.ModuleArchive(ModuleId, ModuleName, ModuleDescription, CourseId)
	    WHERE CourseId IN (SELECT CourseId FROM deleted);

        INSERT INTO Archive.CourseArchive(CourseId, CourseName, Price) SELECT CourseId, CourseName, Price FROM deleted;
        DELETE FROM Study.Course
            WHERE CourseId IN (SELECT CourseId FROM deleted);
    END
GO
-- Восстанавливает из архива курс и все его модули
CREATE PROCEDURE Study.restore_course
    @CourseId INT
AS
    BEGIN
        IF @CourseId NOT IN (SELECT CourseId FROM Archive.CourseArchive)
            THROW 51003, N'Курс с указанным идентификатором отсутствует в архиве!', 10;

        INSERT INTO Study.Course(CourseId, CourseName, Price)
            SELECT CourseId, CourseName, Price FROM Archive.CourseArchive
        WHERE CourseId = @CourseId;

        INSERT INTO Study.Module(ModuleId, ModuleName, ModuleDescription, CourseId)
            SELECT ModuleId, ModuleName, ModuleDescription, CourseId FROM Archive.ModuleArchive
        WHERE CourseId = @CourseId;

        DELETE FROM Archive.CourseArchive WHERE CourseId = @CourseId;
        DELETE FROM Archive.ModuleArchive WHERE CourseId = @CourseId;
    END
GO

INSERT INTO Study.Student(FirstName, LastName, MiddleName, BirthDate, Phone, Email, Gender) VALUES
    ('Иванов', 'Иван', 'Иванович', '20000102', '83452123233', 'ds2122@gmail.com', 'Мужчина');
INSERT INTO Study.Student(FirstName, LastName, MiddleName, BirthDate, Phone, Email, Gender) VALUES
    ('Петров', 'сергей', 'Иванович', '19980308', '83853123003', 'ufg2122@gmail.com', 'Мужчина');
INSERT INTO Study.Student(FirstName, LastName, MiddleName, BirthDate, Phone, Email, Gender) VALUES
    ('Сергеева', 'Вероника', 'Алексеевна', '20011009', '85530002200', 'vs3232@gmail.com', 'Женщина');
INSERT INTO Study.Student(FirstName, LastName, MiddleName, BirthDate, Phone, Email, Gender) VALUES
    ('Петров', 'Кирилл', 'Генадьевич', '19940729', '83452123477', 'kg321@gmail.com', 'Мужчина');

EXEC Study.new_specialization 'Программирование на Python', 5000, 2;

INSERT INTO Study.AcademicGroup(GroupName, Limit, SpecializationId, SemesterId) VALUES ('P-1', 3, 1, NULL);
INSERT INTO Study.AcademicGroup(GroupName, Limit, SpecializationId, SemesterId) VALUES ('P-2', 2, 1, NULL);

INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (1, 1);
INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (2, 1);
INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (3, 1);

INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (2, 2);
INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (3, 2);

INSERT INTO Study.Course(CourseName, Price) VALUES ('Основы Python', 3000);

INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES ('Введение', 'Информация о курсе', 1);
INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES ('Переменные', 'Ввод/вывод', 1);
INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES ('Условные операторы', 'if..elif..else', 1);
INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES ('Циклы', 'for, while', 1);

SELECT * FROM Study.Course;

SELECT * FROM Archive.CourseArchive AS C
    JOIN Archive.ModuleArchive AS M ON C.CourseId = M.CourseId;

SELECT C.CourseId, C.CourseName, M.ModuleName FROM Study.Course AS C
    JOIN Study.Module AS M ON C.CourseId = M.CourseId;

DELETE FROM Study.Course
    WHERE CourseId = 1;

EXEC Study.restore_course 1;