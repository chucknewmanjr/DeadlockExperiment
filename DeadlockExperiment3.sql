use Demo;
go

drop table if exists dbo.Transactions;
go

create table dbo.Transactions (
	TransactionID int not null identity primary key clustered,
	TransactionCode int index IX_TransactionCode,
);
go

create or alter proc p_InsertMissingTransactions as
	/*
		EXEC [dbo].[p_InsertMissingTransactions];
	*/
	set nocount, xact_abort on;

	declare @RowCount int = 10;
	declare @Seconds int = 10;
	declare @Start datetime2(2) = sysdatetime();

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

			--update dbo.Transactions
			--set TransactionCode = CHECKSUM(newid()) % 10000
			--from dbo.Transactions targt
			--join #Transactions src on src.TransactionCode = targt.TransactionCode;

			insert dbo.Transactions (TransactionCode)
			select TransactionCode
			from #Transactions src
			except
			select TransactionCode
			from dbo.Transactions;

			commit;
		end try
		begin catch;
			print concat('~', error_line(), '~');
			rollback;
			throw;
		end catch;
	end;
go

EXEC [Async].[p_Execute] 100, 'EXEC [Demo].[dbo].[p_InsertMissingTransactions];', 0;

select count(*) as DeadlockCount, value as LineNumber
from msdb.dbo.sysjobhistory h
cross apply string_split(message, '~')
where message like '%deadlock%'
	and TRY_CAST(value as int) is not null
group by value;



