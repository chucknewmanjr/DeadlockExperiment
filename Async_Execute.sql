IF SCHEMA_ID('Async') IS NULL EXEC ('CREATE SCHEMA [Async] AUTHORIZATION [dbo]');
GO

CREATE OR ALTER PROC [Async].[p_DeleteJobs] @JobNamePrefix sysname as
	/*
		EXEC [Async].[p_DeleteJobs] @JobNamePrefix = 'Temporary Session Job - ';
	*/
	set nocount, xact_abort on;

	-- Build the set of delete instructions.
	declare @JobDeleteStatements nvarchar(max) = (
		select STRING_AGG(cast('EXEC msdb.dbo.sp_delete_job @job_name = ''' + name + ''';' as varchar(max)), ' ')
		from msdb.dbo.sysjobs
		where name like @JobNamePrefix + '%'
	);

	-- Execute the delete instructions.
	exec (@JobDeleteStatements);
go

CREATE OR ALTER proc [Async].[p_CountJobsRunning] @JobNamePrefix sysname as
	/*
		The key to doing this correctly is the session_id. It has to be the latest.

		declare @ReturnCode int;
		EXEC @ReturnCode = [Async].[p_CountJobsRunning] @JobNamePrefix = 'Temporary Session Job - ';
		select @ReturnCode;
	*/
	set nocount, xact_abort on;

	return (
		SELECT COUNT(*)
		FROM msdb.dbo.sysjobactivity a
		JOIN msdb.dbo.sysjobs j ON a.job_id = j.job_id
		WHERE j.name like '' + '%'
			and a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)
			AND a.start_execution_date IS NOT NULL
			AND a.stop_execution_date IS NULL
	);
GO

create or alter proc [Async].[p_Execute]
	@SessionCount tinyint, -- Number of jobs to create.
	@Command nvarchar(max),
	@CleanUpFlag bit = 0
as
	/*
		Creates and executes jobs that all run at the same time.

		EXEC [Async].[p_Execute] 5, 'WAITFOR DELAY ''00:01:00.000'';'; -- Wait 1 min.
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

	print concat_ws(' - ', sysdatetime(), 'Create and run a job for each session.');

	-- Starting at zero is fine since it gets incremented at the top of the loop.
	declare @ThisSession tinyint = 0;

	-- Using less-than is fine since ... increment.
	while @ThisSession < @SessionCount begin;
		set @ThisSession += 1;

		-- Each job gets its own name.
		declare @JobName sysname = concat('Temporary Session Job - ', @ThisSession);

		-- create the job.
		EXEC msdb.dbo.sp_add_job @job_name = @JobName;

		-- Put SQL commands into a single step inside of that job.
		EXEC msdb.dbo.sp_add_jobstep @job_name = @JobName, @step_name = N'Single Step', @command = @Command;

		-- Creating a job does not set the target server to the obvious choice.
		EXEC msdb.dbo.sp_add_jobserver @job_name = @JobName, @server_name = N'(local)';

		-- Start it asychronusly.
		EXEC msdb.dbo.sp_start_job @job_name = @JobName;
	end; -- End while @ThisSession <= @SessionCount

	print concat_ws(' - ', sysdatetime(), 'Wait for all the jobs to complete.');

	-- Wait until all of the jobs are done.
	set @JobsRunningCount = 255;

	-- Wait until all of the jobs are done.
	while @JobsRunningCount > 0 begin;
		WAITFOR DELAY '00:00:05.000'; -- Wait 5 seconds.

		-- Check again.
		EXEC @JobsRunningCount = [Async].[p_CountJobsRunning] @JobNamePrefix = 'Temporary Session Job - ';
	end;

	if @CleanUpFlag = 1 EXEC [Async].[p_DeleteJobs] @JobNamePrefix = @JobNamePrefix;

	print 'All done';
go


