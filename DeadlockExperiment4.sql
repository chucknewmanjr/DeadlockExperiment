use DeadlockExperiment;
go

drop table if exists dbo.Transactions;
drop table if exists [dbo].[TransactionLog];
go

create table dbo.Transactions (
	TransactionID int not null identity primary key clustered,
	TransactionCode int index IX_TransactionCode,
);
go

create table [dbo].[TransactionLog] (
	SessionNumber tinyint not null primary key clustered,
	TotalUpdates int not null,
	TotalInserts int not null,
);
go

create or alter proc [dbo].[p_PerformTransactions] 
	@SessionNumber tinyint
as
	/*
		truncate table [dbo].[TransactionLog];
		EXEC [dbo].[p_PerformTransactions] 1;
		select * from [dbo].[TransactionLog];
	*/
	set nocount, xact_abort on;

	declare @RowCount int = 10;
	declare @Seconds int = 10;
	declare @Start datetime2(2) = sysdatetime();
	declare @TotalUpdates int = 0;
	declare @TotalInserts int = 0;

	create table #Transactions (
		TransactionCode int not null
	);

	create table #Actions (
		Action varchar(10) not null
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

			merge dbo.Transactions with (xlock) as targt
			using #Transactions as src
				on src.TransactionCode = targt.TransactionCode
			when matched then update set TransactionCode = CHECKSUM(newid()) % 10000
			when not matched then insert (TransactionCode) values (src.TransactionCode)
			output $action into #Actions ([Action]);

			select @TotalUpdates = sum(iif([Action] = 'UPDATE', 1, 0))
				, @TotalInserts = sum(iif([Action] = 'INSERT', 1, 0))
			from #Actions

		end try
		begin catch;
			print concat('~', error_line(), '~');

			insert dbo.TransactionLog (SessionNumber, TotalUpdates, TotalInserts)
			select @SessionNumber, @TotalUpdates, @TotalInserts;

			throw;
		end catch;
	end;

	insert dbo.TransactionLog (SessionNumber, TotalUpdates, TotalInserts)
	select @SessionNumber, @TotalUpdates, @TotalInserts;
go

EXEC [Async].[p_Execute] 100, 'EXEC [Demo].[dbo].[p_PerformTransactions] @SessionNumber = ''[SessionNumber]'';', 0;

select RunStatus
	, LineNumber
	, COUNT(*) as SessionCount
	, AVG(RunSeconds) as AvgSeconds
	, AVG(TotalUpdates + TotalInserts) as AvgTransactions
from [dbo].[vw_DeadlockReport]
group by RunStatus, LineNumber;

select * 
from [dbo].[vw_DeadlockReport]
order by SessionNumber;


