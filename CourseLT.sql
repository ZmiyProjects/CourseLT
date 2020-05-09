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
    CourseName VARCHAR(255) NOT NULL UNIQUE,
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
    Price NUMERIC(9, 2) NOT NULL DEFAULT 0,
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
    CONSTRAINT CK_Limit CHECK (Limit BETWEEN 0 AND 25)
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
-- Возвращает количество студентов в определенгой группе, если она существует, иначе NULL
-- @GroupId - идентификато группы, для которой вычисляется количество студентов
CREATE OR ALTER FUNCTION Study.count_members(@GroupId INT) RETURNS INT AS
    BEGIN
        IF @GroupId NOT IN (SELECT GroupId FROM Study.AcademicGroup)
            RETURN NULL;
        DECLARE @Result INT = (SELECT COUNT(GroupId) FROM Study.StudentGroup WHERE GroupId = @GroupId);
        RETURN @Result;
    END
GO

-- Триггер, вызывающий исключение при попытке вставки в группы чрезмерного числа студентов (больше чем Study.AcademicGroup.Limit)
CREATE TRIGGER Study.check_group_limit ON Study.StudentGroup AFTER INSERT AS
    BEGIN
        IF EXISTS(
            SELECT * FROM inserted AS I
                JOIN Study.AcademicGroup AS AG ON I.GroupId = AG.GroupId AND AG.Limit < Study.count_members(I.GroupId)
            )
        THROW 51001, N'Превышено максимльное число студентов в группе!', 10;
    END

GO
-- Нельзя установить минимальное число студентов меньше, чем уже присутствует в группе
CREATE TRIGGER Study.check_group_limit_update ON Study.AcademicGroup AFTER UPDATE AS
    BEGIN
        IF UPDATE(Limit)
        BEGIN
            IF EXISTS(
                SELECT * FROM inserted AS I
                    WHERE I.Limit < Study.count_members(I.GroupId)
                )
            THROW 51010, N'Нельзя установить минимальное число студентов меньше, чем уже присутствует в группе!', 10;
        END
    END

GO
-- Представления с полными сведениями о группе, включая сведения о специальности к которой она отностися
-- и количевство учащихся (members)
CREATE OR ALTER VIEW Study.GroupInfo AS
    SELECT
           AG.GroupId,
           AG.GroupName,
           S.SpecializationName,
           S.Price,
           AG.Limit AS max_members,
           Study.count_members(AG.GroupId) AS members
    FROM Study.AcademicGroup AS AG
        JOIN Study.Specialization AS S ON AG.SpecializationId = S.SpecializationId
GO

-- Вставка новой специализации
-- @Name - название специальности, в базе не должно быть одноименной специальности
-- @Duration - продолжительность обучения в семестрах (от 2 до 4)
CREATE OR ALTER PROCEDURE Study.new_specialization
    @Name VARCHAR(255),
    @Duration SMALLINT
AS
    BEGIN
        DECLARE
            @Counter INT = 1,
            @SpecializationId INT = NEXT VALUE FOR Study.SeqSpecialization;
        INSERT INTO Study.Specialization(SpecializationId, SpecializationName, Duration) VALUES (@SpecializationId, @Name, @Duration);
        WHILE @Counter <= @Duration
        BEGIN
            INSERT INTO Study.Semester(SemesterNumber, SpecializationId) VALUES (@Counter, @SpecializationId);
            SET @Counter += 1;
        END
    END

GO
-- Вычисление суммарной стоимости курсов, входящих в специализацию,
-- если специальность с указанным идентификатором отсутствует - вернет NULL
-- @SpecializationId идентификатор специальности, для которой осуществляется вычисление
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

-- Представление демонстрирующее все зарегиситрированные в системе курсы, включая архивные
CREATE OR ALTER VIEW Study.AllCourses WITH SCHEMABINDING AS
    SELECT C.CourseId, C.CourseName, C.Price, N'Действующий' AS status FROM Study.Course AS C
    UNION
    SELECT CA.CourseId, CA.CourseName, CA.Price, N'Архивный' AS status FROM Archive.CourseArchive AS CA;
GO

-- Проверяет наличие курса с указанным названием в архиве, если присутствует вернет 1, иначе 0
-- @Name - название курса, для которого осуществляется проверка
CREATE OR ALTER FUNCTION Study.check_course_in_archive(@Name VARCHAR(255)) RETURNS BIT AS
    BEGIN
        IF @Name IN (SELECT CourseName FROM Archive.CourseArchive)
            RETURN 1;
        RETURN 0;
    END

GO

-- Триггер, изменяющий стоимость специализации, при изменении цены входящего в неё курса
CREATE OR ALTER TRIGGER Study.check_course ON Study.Course AFTER UPDATE AS
    BEGIN
        IF UPDATE(Price)
        BEGIN
            UPDATE Study.Specialization SET
                Price = Study.sum_course_price(S.SpecializationId)
            FROM inserted AS I
                JOIN Study.Curriculum AS C ON I.CourseId = c.CourseId
                JOIN Study.Semester AS S ON C.SemesterId = S.SemesterId;
        END
    END
GO

-- Создание нового курса, с учетом ранее обозначенных ограничений
-- @Name - название курса, в базе (учитывая архив) не должно быть одноименной специальности
-- @Price - стоимость курса, 0, если курс бесплатный
CREATE OR ALTER PROCEDURE Study.new_course
    @Name VARCHAR(255),
    @Price NUMERIC(9, 2)
AS
    BEGIN
        IF Study.check_course_in_archive(@Name) = 1
            THROW 51002, N'Курс с заданным именем присутствует в архиве!', 10;
        INSERT INTO Study.Course(CourseName, Price) VALUES (@Name, @Price);
    END

GO

-- Переименование курса
-- @CourseId - идентификатор курса, если в базе откутствует курс с заданным идентификаторум - будет вызвано исключение
-- @NewName - новое наименование курса, с учетом ранее обозначенных правил именование (не должно повторяться в БД, включая архив)
CREATE OR ALTER PROCEDURE Study.rename_course
    @CourseId INT,
    @NewName VARCHAR(255)
AS
    BEGIN
        IF Study.check_course_in_archive(@NewName) = 1
            THROW 51002, N'Курс с заданным именем присутствует в архиве!', 10;
        UPDATE Study.Course SET
            CourseName = @NewName
        WHERE CourseId = @CourseId;
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
-- @CourseId - идентификатор архивного курса, который необходимо восстановить,
-- если такого курса нет в архиве - будет вызвано исключение
CREATE OR ALTER PROCEDURE Study.restore_course
    @CourseId INT
AS
    BEGIN
        IF @CourseId NOT IN (SELECT CourseId FROM Archive.CourseArchive)
            THROW 51003, N'Курс с указанным идентификатором отсутствует в архиве!', 10;

        DECLARE @Course TABLE(CourseId INT, CourseName VARCHAR(255), Price NUMERIC(9, 2));
        DECLARE @Module TABLE(ModuleId INT, ModuleName VARCHAR(255), ModuleDescription VARCHAR(255), CourseId INT);

        INSERT INTO @Course(CourseId, CourseName, Price)
            SELECT CourseId, CourseName, Price FROM Archive.CourseArchive
        WHERE CourseId = @CourseId;

        INSERT INTO @Module(ModuleId, ModuleName, ModuleDescription, CourseId)
            SELECT ModuleId, ModuleName, ModuleDescription, CourseId FROM Archive.ModuleArchive
        WHERE CourseId = @CourseId;

        DELETE FROM Archive.CourseArchive WHERE CourseId = @CourseId;
        DELETE FROM Archive.ModuleArchive WHERE CourseId = @CourseId;

        INSERT INTO Study.Course(CourseId, CourseName, Price)
            SELECT CourseId, CourseName, Price FROM @Course

        INSERT INTO Study.Module(ModuleId, ModuleName, ModuleDescription, CourseId)
            SELECT ModuleId, ModuleName, ModuleDescription, CourseId FROM @Module
    END
GO
-- изменение стоимости специализации в зависимости от назначения и/или удаления курсов на входящие в специализацию семестры
CREATE TRIGGER Study.calculate_price ON Study.Curriculum AFTER INSERT, UPDATE, DELETE AS
    BEGIN
        UPDATE Study.Specialization SET
            Price = Study.sum_course_price(S.SpecializationId)
        FROM inserted AS I
            JOIN Semester AS S ON I.SemesterId = S.SemesterId
    END

GO

-- Роли и пользователи
CREATE ROLE CourseLTManager;

GRANT SELECT ON SCHEMA::Archive TO CourseLTManager;

GRANT EXECUTE, SELECT, INSERT, UPDATE, DELETE ON SCHEMA::Study TO CourseLTManager;

DENY INSERT ON Study.Course TO CourseLTManager;
DENY INSERT ON Study.Specialization TO CourseLTManager;
DENY UPDATE ON Study.Specialization(Duration, Price) TO CourseLTManager;
DENY DELETE, UPDATE ON Study.Semester TO CourseLTManager;
DENY UPDATE ON Study.Course(CourseName) TO CourseLTManager;

IF EXISTS(SELECT * FROM sys.server_principals WHERE name = 'CourseLTManagerOne')
    DROP LOGIN CourseLTManagerOne;

CREATE LOGIN CourseLTManagerOne WITH
    PASSWORD = 'test',
    DEFAULT_DATABASE = CourseLT;

CREATE USER CourseLTManagerOne FOR LOGIN CourseLTManagerOne;

ALTER ROLE CourseLTManager
    ADD MEMBER CourseLTManagerOne;

-- Заполнение для тестирования
EXECUTE AS LOGIN = 'CourseLTManagerOne'
    INSERT INTO Study.Student(FirstName, LastName, MiddleName, BirthDate, Phone, Email, Gender) VALUES
        (N'Иванов', N'Иван', N'Иванович', '20000102', '83452123233', 'ds2122@gmail.com', N'Мужчина');
    INSERT INTO Study.Student(FirstName, LastName, MiddleName, BirthDate, Phone, Email, Gender) VALUES
        (N'Петров', N'Сергей', N'Иванович', '19980308', '83853123003', 'ufg2122@gmail.com', N'Мужчина');
    INSERT INTO Study.Student(FirstName, LastName, MiddleName, BirthDate, Phone, Email, Gender) VALUES
        (N'Сергеева', N'Вероника', N'Алексеевна', '20011009', '85530002200', 'vs3232@gmail.com', N'Женщина');
    INSERT INTO Study.Student(FirstName, LastName, MiddleName, BirthDate, Phone, Email, Gender) VALUES
        (N'Петров', N'Кирилл', N'Генадьевич', '19940729', '83452123477', 'kg321@gmail.com', N'Мужчина');


    EXEC Study.new_specialization N'Программирование на Python', 2;

    INSERT INTO Study.AcademicGroup(GroupName, Limit, SpecializationId) VALUES ('P-1', 8, 1);
    INSERT INTO Study.AcademicGroup(GroupName, Limit, SpecializationId) VALUES ('P-2', 5, 1);

    INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (1, 1);
    INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (2, 1);
    INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (3, 1);

    INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (2, 2);
    INSERT INTO Study.StudentGroup(StudentId, GroupId) VALUES (3, 2);

    EXEC Study.new_course N'Основы Python', 3000;
    EXEC Study.new_course N'Системы контроля версий и git', 2000;
    EXEC Study.new_course N'Базы данных', 4000;

    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Введение', N'Информация о курсе', 1);
    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Переменные', N'Ввод/вывод', 1);
    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Условные операторы', 'if..elif..else', 1);
    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Циклы', 'for, while', 1);

    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Введение', N'Назначение системы контроля версий', 2);
    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Базовые команды', 'add, commit, log', 2);
    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Хранение в облаке', N'Знакомство с GitHub', 2);

    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Основы проектирования БД', N'ER-модель, нормализация', 3);
    INSERT INTO Study.Module(ModuleName, ModuleDescription, CourseId) VALUES (N'Основы SQL', N'CRUD операции', 3);

    INSERT INTO Study.Curriculum(CourseId, SemesterId) VALUES (1, 1);
    INSERT INTO Study.Curriculum(CourseId, SemesterId) VALUES (2, 1);
    INSERT INTO Study.Curriculum(CourseId, SemesterId) VALUES (3, 2);
REVERT;
