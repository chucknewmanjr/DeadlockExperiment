create or alter view [dbo].[vw_DeadlockReport] as
	with ErrorLines as (
		select m.SessionNumber, v.value as LineNumber
		FROM [Async].[f_SessionMessage](DEFAULT) m
		cross apply string_split(message, '~') v
		where TRY_CAST(v.value as int) is not null
	)
	select cast(sm.SessionNumber as int) as SessionNumber
		, sm.RunStatus
		, sm.RunSeconds
		, sm.[Message]
		, tl.TotalUpdates
		, tl.TotalInserts
		, el.LineNumber
	from [Async].[f_SessionMessage](DEFAULT) sm
	left join [dbo].[TransactionLog] tl on tl.SessionNumber = sm.SessionNumber
	left join ErrorLines el on el.SessionNumber = sm.SessionNumber;
go


