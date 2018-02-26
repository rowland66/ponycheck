use "debug"
use "collections"

interface val PropertyLogger
  fun log(msg: String, verbose: Bool = false)

interface val PropertyResultNotify
  fun fail(msg: String)
    """
    called when a Property has failed (did not hold for a sample)
    or when execution errored.

    Does not necessarily denote completeness of the property execution,
    see `complete(success: Bool)` for that purpose.
    """

  fun complete(success: Bool)
    """
    called when the Property execution is complete
    signalling whether it was successful or not.
    """

actor PropertyRunner[T]
  """
  Actor executing a Property1 implementation
  in a way that allows garbage collection between single
  property executions, because it uses recursive behaviours
  for looping.
  """
  let _prop1: Property1[T]
  let _params: PropertyParams
  let _rnd: Randomness
  let _notify: PropertyResultNotify
  let _gen: Generator[T]
  let _logger: PropertyLogger

  let _expected_actions: Set[String] = Set[String]
  var _shrinker: Iterator[T^] = _EmptyIterator[T^]
  var _sample_repr: String = ""
  var _pass: Bool = true

  new create(
    p1: Property1[T] iso,
    params: PropertyParams,
    notify: PropertyResultNotify,
    logger: PropertyLogger
  ) =>
    _prop1 = consume p1
    _params = params
    _logger = logger
    _notify = notify
    _rnd = Randomness(_params.seed)
    _gen = _prop1.gen()

// RUNNING PROPERTIES //

  be complete_run(round: USize, success: Bool) =>
    """
    complete a property run

    this behaviour is called from the PropertyHelper
    or from `_finished`.
    """
    _pass = success // in case of sync property - signal failure

    if not success then
      // found a bad example, try to shrink it
      if not _shrinker.has_next() then
        _logger.log("no shrinks available")
        fail(_sample_repr, 0)
      else
        do_shrink(_sample_repr)
      end
    else
      // property holds, recurse
      run(round + 1)
    end

  be run(round: USize = 0) =>
    if round >= _params.num_samples then
      complete() // all samples have been successful
      return
    end

    // prepare property run
    (var sample, _shrinker) = _gen.generate_and_shrink(_rnd)
    // create a string representation before consuming ``sample`` with property
    (sample, _sample_repr) = _Stringify.apply[T](consume sample)
    let run_notify = recover val this~complete_run(round) end
    let helper = PropertyHelper(this, run_notify, _params.string() + " Run(" +
    round.string() + ")")
    _pass = true // will be set to false by fail calls

    try
      _prop1.property(consume sample, helper)?
    else
      fail(_sample_repr, 0 where err=true)
      return
    end
    // dispatch to another behavior
    // as complete_run might have set _pass already through a call to
    // complete_run
    _run_finished(round)

  be _run_finished(round: USize) =>
    if not _params.async and _pass then
      // otherwise complete_run has already been called
      complete_run(round, true)
    end

// SHRINKING //

  be complete_shrink(shrink_repr: String, shrink_round: USize, success: Bool) =>

    _pass = success // in case of sync property - signal failure

    if success then
      // we have a sample that did not fail and thus can stop shrinking
      //_logger.log("shrink: " + shrink_repr + " did not fail")
      fail(shrink_repr, shrink_round)

    else
      // we have a failing shrink sample, recurse
      //_logger.log("shrink: " + shrink_repr + " did fail")
      do_shrink(shrink_repr, shrink_round + 1)
    end

  be do_shrink(repr: String, shrink_round: USize = 0) =>

    // shrink iters can be infinite, so we need to limit
    // the examples we consider during shrinking
    if shrink_round == _params.max_shrink_rounds then
      fail(repr, shrink_round)
      return
    end

    (let shrink, let shrink_repr) =
      try
        _Stringify.apply[T](_shrinker.next()?)
      else
        // no more shrink samples, report previous failed example
        fail(repr, shrink_round)
        return
      end
    // callback for asynchronous shrinking or aborting on error case
    let run_notify =
      recover val
        this~complete_shrink(shrink_repr, shrink_round)
      end
    let helper = PropertyHelper(
      this,
      run_notify,
      _params.string() + " Shrink(" + shrink_round.string() + ")")
    _pass = true // will be set to false by fail calls

    try
      _prop1.property(consume shrink, helper)?
    else
      fail(shrink_repr, shrink_round where err=true)
      return
    end
    // dispatch to another behaviour
    // to ensure _complete_shrink has been called already
    _shrink_finished(shrink_repr, shrink_round)

  be _shrink_finished(shrink_repr: String, shrink_round: USize) =>
    if not _params.async and _pass then
      // directly complete the shrink run
      complete_shrink(shrink_repr, shrink_round, true)
    end

// interface towards PropertyHelper

  be expect_action(name: String) =>
    _logger.log("Action expected: " + name)
    _expected_actions.set(name)

  be complete_action(name: String, ph: PropertyHelper) =>
    _logger.log("Action completed: " + name)
    _finish_action(name, true, ph)

  be fail_action(name: String, ph: PropertyHelper) =>
    _logger.log("Action failed: " + name)
    _finish_action(name, false, ph)

  fun ref _finish_action(name: String, success: Bool, ph: PropertyHelper) =>
    _expected_actions.unset(name)

    // call back into the helper to invoke the current run_notify
    // that we don't have access to otherwise
    if not success then
      ph.complete(false)
    elseif _expected_actions.size() == 0 then
      ph.complete(true)
    end

  be log(msg: String, verbose: Bool = false) =>
    _logger.log(msg, verbose)

  // end interface towards PropertyHelper

  fun ref complete() =>
    """
    complete the Property execution successfully
    """
    _notify.complete(true)

  fun ref fail(repr: String, rounds: USize = 0, err: Bool = false) =>
    """
    complete the Property execution
    while signalling failure to the notify
    """
    if err then
      _report_error(repr, rounds)
    else
      _report_failed(repr, rounds)
    end
    _notify.complete(false)

  fun _report_error(sample_repr: String,
    shrink_rounds: USize = 0,
    loc: SourceLoc = __loc) =>
    """
    report an error that happened during property evaluation
    and signal failure to the notify
    """
    _notify.fail(
      "Property errored for sample "
        + sample_repr
        + " (after "
        + shrink_rounds.string()
        + " shrinks)"
    )

  fun _report_failed(sample_repr: String,
    shrink_rounds: USize = 0,
    loc: SourceLoc = __loc) =>
    """
    report a failed property and signal failure to the notify
    """
    _notify.fail(
      "Property failed for sample "
        + sample_repr
        + " (after "
        + shrink_rounds.string()
        + " shrinks)"
    )


class _EmptyIterator[T]
  fun ref has_next(): Bool => false
  fun ref next(): T^ ? => error

primitive _Stringify
  fun apply[T](t: T): (T^, String) =>
    """turn anything into a string"""
    let digest = (digestof t)
    let s =
      match t
      | let str: Stringable =>
        str.string()
      | let rs: ReadSeq[Stringable] =>
        "[" + " ".join(rs.values()) + "]"
      else
        "<identity:" + digest.string() + ">"
      end
    (consume t, consume s)

