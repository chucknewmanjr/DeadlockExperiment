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

			update dbo.Transactions
			set TransactionCode = CHECKSUM(newid()) % 10000
			from dbo.Transactions targt
			join #Transactions src on src.TransactionCode = targt.TransactionCode;

			set @TotalUpdates += @@rowcount;

			insert dbo.Transactions (TransactionCode)
			select TransactionCode
			from #Transactions src
			where not exists (
					select *
					from dbo.Transactions targt
					where targt.TransactionCode = src.TransactionCode
				);

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

EXEC [Async].[p_Execute] 100, 'EXEC [Demo].[dbo].[p_InsertMissingTransactions];', 0;

select count(*) as DeadlockCount, value as LineNumber
from msdb.dbo.sysjobhistory h
cross apply string_split(message, '~')
where message like '%deadlock%'
	and TRY_CAST(value as int) is not null
group by value;

select * 
from [dbo].[vw_DeadlockReport]
order by SessionNumber;


