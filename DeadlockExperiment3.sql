use Demo;
go

drop table if exists dbo.Transactions;
drop table if exists dbo.TransactionLog;
go

create table dbo.Transactions (
	TransactionID int not null identity primary key clustered,
	TransactionCode int index IX_TransactionCode,
);
go

create table dbo.TransactionLog (
	TransactionLogID int not null identity primary key clustered,
	CreatedOn datetime2(2) not null default sysdatetime(),
	SPID int not null default @@SPID,
	SessionNumber tinyint not null,
	TotalUpdates int not null,
	TotalInserts int not null
);
go

create or alter proc p_PerformTransactions 
	@SessionNumber tinyint
as
	/*
		EXEC [dbo].[p_PerformTransactions];
	*/
	set nocount, xact_abort on;

	declare @RowCount int = 10;
	declare @Seconds int = 10;
	declare @Start datetime2(2) = sysdatetime();
	declare @TotalUpdates int = 0;
	declare @TotalInserts int = 0;

	create table #Transactions (
		TransactionCode int
	);

	while DATEDIFF(second, @Start, sysdatetime()) < @Seconds begin; 
		truncate table #Transactions;

		-- Generate test data.
		with RecursiveCTE1 as (
				select 1 as RowNumber
				union all
				select RowNumber + 1
				from RecursiveCTE1
				where RowNumber < @RowCount
			)
		insert #Transactions (TransactionCode)
		select CHECKSUM(newid()) % 10000 as TransactionCode
		from RecursiveCTE1
		OPTION (MAXRECURSION 0);

		begin try;
			-- Put update and insert in a transaction.
			begin tran;

			update dbo.Transactions with (xlock)
			set TransactionCode = CHECKSUM(newid()) % 10000
			from dbo.Transactions targt
			join #Transactions src on src.TransactionCode = targt.TransactionCode;

			set @TotalUpdates += @@rowcount;

			insert dbo.Transactions (TransactionCode)
			select TransactionCode
			from #Transactions src
			except
			select TransactionCode
			from dbo.Transactions;

			set @TotalInserts += @@rowcount;

			commit;
		end try
		begin catch;
			print concat('~', error_line(), '~');

			rollback;

			insert dbo.TransactionLog (SessionNumber, TotalUpdates, TotalInserts)
			select @SessionNumber, @TotalUpdates, @TotalInserts;

			throw;
		end catch;
	end;

	insert dbo.TransactionLog (SessionNumber, TotalUpdates, TotalInserts)
	select @SessionNumber, @TotalUpdates, @TotalInserts;
go

EXEC [Async].[p_Execute] 100, 'EXEC [Demo].[dbo].[p_PerformTransactions] @SessionNumber = ''[SessionNumber]'';', 0;

SELECT m.RunStatus
	, COUNT(distinct SessionNumber) as SessionCount
	, avg(m.RunSeconds) as AvgSeconds
	, iif(message like '%deadlock%', TRY_CAST(value as int), 0) as DeadlockLineNumber
FROM [Async].[f_SessionMessage](DEFAULT) m
cross apply string_split(message, '~') v
group by m.RunStatus, iif(message like '%deadlock%', TRY_CAST(value as int), 0)
order by 1;

/*
		SELECT * FROM [Async].[f_SessionMessage](DEFAULT);
--*/

select m.SessionNumber, m.RunStatus, m.RunSeconds, l.SessionNumber, l.TotalUpdates, l.TotalInserts
from [Async].[f_SessionMessage](DEFAULT) m
left join dbo.TransactionLog l on m.SessionNumber = l.SessionNumber
order by cast(m.SessionNumber as int);




