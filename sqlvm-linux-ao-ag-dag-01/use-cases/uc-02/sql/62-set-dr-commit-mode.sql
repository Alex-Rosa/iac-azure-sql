-- UC-02 | PRIMARY | Availability mode of the DR replica: SYNCHRONOUS_COMMIT for the synchronous variant of
-- the drill (commits then wait for the DR replica, until it is lost and the session times out),
-- ASYNCHRONOUS_COMMIT to restore the lab's normal mode.
-- sqlcmd -v AgName="agsqlvm-node-1" Replica="sqlvm-ag01-node-2" Mode="SYNCHRONOUS_COMMIT" -i 62-set-dr-commit-mode.sql
SET NOCOUNT ON;
ALTER AVAILABILITY GROUP [$(AgName)] MODIFY REPLICA ON N'$(Replica)' WITH (AVAILABILITY_MODE = $(Mode));
SELECT 'COMMIT_MODE=' + ar.replica_server_name + '|' + ar.availability_mode_desc COLLATE DATABASE_DEFAULT
     + '|session_timeout=' + CAST(ar.session_timeout AS varchar(10))
FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
WHERE ag.name = N'$(AgName)';
