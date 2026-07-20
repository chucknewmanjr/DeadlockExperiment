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

	declare @RowCount int = 5;
	declare @Seconds int = 5;
	declare @Start datetime2(2) = sysdatetime();
	declare @TotalUpdates int = 0;
	declare @TotalInserts int = 0;

	create table #Transactions (
		TransactionCode int not null
	);

	while DATEDIFF(second, @Start, sysdatetime()) < @Seconds begin; 
		truncate table #Transactions;

		begin try;
			-- Put update and insert in a transaction.
			begin tran;

			-- Generate test data.
			-- This is inside the transaction so that TABLOCK holds.
			with RecursiveCTE1 as (
					select 1 as RowNumber
					union all
					select RowNumber + 1
					from RecursiveCTE1
					where RowNumber < @RowCount
				)
			insert #Transactions with (tablock) (TransactionCode)
			select CHECKSUM(newid()) % 10000 as TransactionCode
			from RecursiveCTE1
			OPTION (MAXRECURSION 0);

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

EXEC [Async].[p_Execute] 100, 'EXEC [dbo].[p_PerformTransactions] @SessionNumber = ''[SessionNumber]'';', 0;

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


