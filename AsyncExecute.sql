use DeadlockExperiment;
go

IF SCHEMA_ID('Async') IS NULL EXEC ('CREATE SCHEMA [Async] AUTHORIZATION [dbo]');
GO

CREATE OR ALTER PROC [Async].[p_DeleteJobs] 
	@JobNamePrefix sysname = 'Temporary Session Job - ' 
as
	/*
		This proc deletes all the jobs 
		with names that begin with the value of @JobNamePrefix.
		It does not check if that jobs are running.
		That's what [Async].[p_CountJobsRunning] is for.

		EXEC [Async].[p_DeleteJobs] @JobNamePrefix = 'Temporary Session Job - ';

		declare @JobsRunningCount tinyint;
		EXEC @JobsRunningCount = [Async].[p_CountJobsRunning];
		if @JobsRunningCount = 0 EXEC [Async].[p_DeleteJobs];
	*/
	set nocount, xact_abort on;

	-- Build the set of delete instructions.
	-- Cast as max so it can handle lots of jobs.
	declare @JobDeleteStatements nvarchar(max) = (
		select STRING_AGG(cast('EXEC msdb.dbo.sp_delete_job @job_name = ''' + name + ''';' as varchar(max)), ' ')
		from msdb.dbo.sysjobs
		where name like @JobNamePrefix + '%'
	);

	-- Execute all the instructions at once.
	exec (@JobDeleteStatements);
go

CREATE OR ALTER proc [Async].[p_CountJobsRunning] 
	@JobNamePrefix sysname = 'Temporary Session Job - ' 
as
	/*
		This proc returns the number jobs running
		with names that begin with the value of @JobNamePrefix.
		The key to doing this correctly is the session_id. 
		It has to be the latest from msdb.dbo.syssessions.

		declare @JobsRunningCount int = 1;
		while @JobsRunningCount > 0 begin;
			WAITFOR DELAY '00:00:05.000'; -- Wait 5 seconds.
			EXEC @JobsRunningCount = [Async].[p_CountJobsRunning];
		end;
	*/
	set nocount, xact_abort on;

	return (
		SELECT COUNT(*)
		FROM msdb.dbo.sysjobactivity a
		JOIN msdb.dbo.sysjobs j ON a.job_id = j.job_id
		WHERE j.name like @JobNamePrefix + '%'
			-- Only check the latest session_id.
			and a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
			AND a.start_execution_date IS NOT NULL
			AND a.stop_execution_date IS NULL
	);
GO

CREATE or alter function [Async].[f_SessionMessage] (
	@JobNamePrefix sysname = 'Temporary Session Job - '
) 
returns table as return (
	/*
		This function returns a resultset 
		with 6 columns and a row for each job or session.
			- SessionNumber - It's cut from the job name.
			- RunStatus - 5 text values. It's usually Succeeded or Failed.
			- sql_severity - Severity number of SQL Server error. Usually zero.
			- message - From print statements and error messages.
			- StartTime
			- RunSeconds

		SELECT * FROM [Async].[f_SessionMessage](DEFAULT);

		SELECT * 
		FROM [Async].[f_SessionMessage](DEFAULT) m
		cross apply string_split(m.message, '~') v
		where TRY_CAST(v.value as int) is not null;
	*/
	select cast(trim(substring(
			j.[name], 
			len(@JobNamePrefix) + 1, 
			99
		)) as int) as SessionNumber
		, IIF(
			h.run_status = 0, 
			'Failed', 
			choose(h.run_status, 'Succeeded', 'Retry', 'Canceled', 'In progress')
		) as RunStatus
		, h.sql_severity
		, h.[message]
		, MSDB.DBO.AGENT_DATETIME(h.run_date, h.run_time) as StartTime
		, h.run_duration / 10000 * 3600 
			+ h.run_duration % 10000 / 100 
			* 60 + h.run_duration % 100 as RunSeconds
	from msdb.dbo.sysjobs j
	join msdb.dbo.sysjobhistory h on h.job_id = j.job_id
	where j.name like @JobNamePrefix + '%'
		and step_id = 1
);
go

create or alter proc [Async].[p_Execute]
	@SessionCount tinyint, -- Number of jobs to create.
	@CommandText nvarchar(max) -- Include [SessionNumber] if you want.
as
	/*
		Creates and executes jobs that all run at the same time.
		That's because each job runs in it's own session.
		The sp_start_job command returns imediately event though the job is still running.
		This proc does not complete until all the jobs have completed.

			@SessionCount - is the number of jobs you want.
			@CommandText - Is the SQL instructions that each job will execute.
				That command tect can contain "[SessionNumber]".
				It gets replaced with a number for each job.
			@CleanUpFlag - 1 means all the jobs get deleted at the end.

		EXEC [Async].[p_Execute] 5, 'WAITFOR DELAY ''00:01:00.000'';', 0; -- Wait 1 min.

		EXEC [Async].[p_Execute] 100, 'PRINT ''~[SessionNumber]~'';', 0; -- See session number in messages.

		SELECT * 
		FROM [Async].[f_SessionMessage](NULL) m
		cross apply string_split(m.message, '~') v
		where TRY_CAST(v.value as int) is not null;
	*/
	set nocount, xact_abort on;

	declare @JobNamePrefix sysname = 'Temporary Session Job - ';
	declare @JobsRunningCount tinyint;

	print concat_ws(' - ', sysdatetime(), 'Check if running and delete jobs.');

	-- Check if any of the jobs like this are still running.
	EXEC @JobsRunningCount = [Async].[p_CountJobsRunning] @JobNamePrefix = @JobNamePrefix;

	-- Error out if any are still running.
	if @JobsRunningCount <> 0 throw 50000, 'A job with a name like this is still running.', 1;

	-- Delete these jobs.
	EXEC [Async].[p_DeleteJobs] @JobNamePrefix = @JobNamePrefix;

	declare @DatabaseName sysname = db_name();
	declare @SessionNumber tinyint;
	declare @JobName sysname;
	declare @Command nvarchar(max);

	print concat_ws(' - ', sysdatetime(), 'Create a job for each session.');

	-- Starting at zero is fine since it gets incremented at the top of the loop.
	set @SessionNumber = 0;

	-- Using less-than is fine since ... increment.
	while @SessionNumber < @SessionCount begin;
		set @SessionNumber += 1;

		-- Each job gets its own name.
		set @JobName = concat(@JobNamePrefix, @SessionNumber);

		-- The command might have the [SessionNumber] placeholder in it.
		set @Command = replace(@CommandText, '[SessionNumber]', @SessionNumber);

		-- create the job.
		EXEC msdb.dbo.sp_add_job 
			@job_name = @JobName;

		-- Put SQL commands into a single step inside of that job.
		EXEC msdb.dbo.sp_add_jobstep 
			@job_name = @JobName, 
			@step_name = N'Single Job Step', 
			@Command = @Command, 
			@database_name = @DatabaseName;

		-- Creating a job does not set the target server to the obvious choice.
		EXEC msdb.dbo.sp_add_jobserver 
			@job_name = @JobName, 
			@server_name = N'(local)';
	end; -- End while @SessionNumber <= @SessionCount

	-- Jobs are started in a separate loop so that they start closer together.
	print concat_ws(' - ', sysdatetime(), 'Run the job for each session.');

	set @SessionNumber = 0;

	while @SessionNumber < @SessionCount begin;
		set @SessionNumber += 1;

		set @JobName = concat(@JobNamePrefix, @SessionNumber);

		-- Start it asychronusly.
		EXEC msdb.dbo.sp_start_job @job_name = @JobName;
	end; -- End while @SessionNumber <= @SessionCount

	print concat_ws(' - ', sysdatetime(), 'All started.');
go

create or alter proc [Async].[p_Wait]
	@JobNamePrefix sysname = 'Temporary Session Job - '
as
	/*
		EXEC [Async].[p_Wait];
	*/
	set nocount, xact_abort on;

	print concat_ws(' - ', sysdatetime(), 'Start waiting for jobs to end.');

	declare @JobsRunningCount tinyint = 1;

	while @JobsRunningCount > 0 begin;
		WAITFOR DELAY '00:00:05.000'; -- 5 seconds.

		-- Check again.
		EXEC @JobsRunningCount = [Async].[p_CountJobsRunning] @JobNamePrefix = @JobNamePrefix;
	end;

	print concat_ws(' - ', sysdatetime(), 'Jobs are all done.');
go

create or alter proc [Async].[p_GetTransactionIsolationLevel] as
	/*
		EXEC [Async].[p_GetTransactionIsolationLevel];
	*/
	set nocount, xact_abort on;

	create table #UserOptions (
		SetOption sysname, 
		isolation_level sysname
	);

	insert #UserOptions exec('DBCC USEROPTIONS;');

	select uo.isolation_level
		, db.is_read_committed_snapshot_on
		, db.snapshot_isolation_state
	from #UserOptions uo
	cross join sys.databases db
	where uo.SetOption = 'isolation level'
		and db.database_id = db_id();
go

create or alter view [Async].[v_Locks] as
	/*
		select * 
		from [Async].[v_Locks]
		order by TableName, IndexName, SessionID;
	*/
	with indexes as (
		select p.hobt_id, p.object_id, i.name as IndexName
		from sys.indexes i 
		join sys.partitions p
		on i.object_id = p.object_id and i.index_id = p.index_id
	)
	select ISNULL(
			OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id),
			OBJECT_SCHEMA_NAME(o.object_id) + '.' + OBJECT_NAME(o.object_id)
		) as TableName
		, i.IndexName
		, l.request_session_id as SessionID
		, l.resource_type as ResourceType
		, l.request_mode as Mode
		, COUNT(*) as Occurs
		, t.blocking_session_id as BlockingSessionID
	from sys.dm_tran_locks l
	left join sys.objects o on o.object_id = l.resource_associated_entity_id -- OBJECT
	left join indexes i on i.hobt_id = l.resource_associated_entity_id -- KEY, PAGE
	left join sys.dm_os_waiting_tasks t on t.resource_address = l.lock_owner_address
	where resource_database_id = DB_ID()
	group by l.resource_type
		, l.request_mode
		, l.request_session_id
		, o.object_id
		, i.object_id
		, i.IndexName
		, t.blocking_session_id;
go


