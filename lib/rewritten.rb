require 'redis/namespace'
require 'rewritten/version'
require 'rewritten/helpers'
require 'rack/dummy'
require 'rack/url'
require 'rack/record'
require 'rack/html'
require 'rack/subdomain'

module Rewritten
  include Helpers
  extend self

  # Accepts:
  #   1. A 'hostname:port' String
  #   2. A 'hostname:port:db' String (to select the Redis db)
  #   3. A 'hostname:port/namespace' String (to set the Redis namespace)
  #   4. A Redis URL String 'redis://host:port'
  #   5. An instance of `Redis`, `Redis::Client`, `Redis::DistRedis`,
  #      or `Redis::Namespace`.
  def redis=(server)
    case server
    when String
      if server =~ /redis\:\/\//
        redis = Redis.connect(:url => server, :thread_safe => true)
      else
        server, namespace = server.split('/', 2)
        host, port, db = server.split(':')
        redis = Redis.new(:host => host, :port => port,
          :thread_safe => true, :db => db)
      end
      namespace ||= :rewritten

      @redis = Redis::Namespace.new(namespace, :redis => redis)
    when Redis::Namespace
      @redis = server
    else
      @redis = Redis::Namespace.new(:rewritten, :redis => server)
    end
  end

  # Returns the current Redis connection. If none has been created, will
  # create a new one.
  def redis
    return @redis if @redis
    self.redis = Redis.respond_to?(:connect) ? Redis.connect : "localhost:6379"
    self.redis
  end

  def redis_id
    # support 1.x versions of redis-rb
    if redis.respond_to?(:server)
      redis.server
    elsif redis.respond_to?(:nodes) # distributed
      redis.nodes.map { |n| n.id }.join(', ')
    else
      redis.client.id
    end
  end

  # The `before_first_fork` hook will be run in the **parent** process
  # only once, before forking to run the first job. Be careful- any
  # changes you make will be permanent for the lifespan of the
  # worker.
  #
  # Call with a block to set the hook.
  # Call with no arguments to return the hook.
  def before_first_fork(&block)
    block ? (@before_first_fork = block) : @before_first_fork
  end

  # Set a proc that will be called in the parent process before the
  # worker forks for the first time.
  def before_first_fork=(before_first_fork)
    @before_first_fork = before_first_fork
  end

  # The `before_fork` hook will be run in the **parent** process
  # before every job, so be careful- any changes you make will be
  # permanent for the lifespan of the worker.
  #
  # Call with a block to set the hook.
  # Call with no arguments to return the hook.
  def before_fork(&block)
    block ? (@before_fork = block) : @before_fork
  end

  # Set the before_fork proc.
  def before_fork=(before_fork)
    @before_fork = before_fork
  end

  # The `after_fork` hook will be run in the child process and is passed
  # the current job. Any changes you make, therefore, will only live as
  # long as the job currently being processed.
  #
  # Call with a block to set the hook.
  # Call with no arguments to return the hook.
  def after_fork(&block)
    block ? (@after_fork = block) : @after_fork
  end

  # Set the after_fork proc.
  def after_fork=(after_fork)
    @after_fork = after_fork
  end

  def to_s
    "Rewritten Client connected to #{redis_id}"
  end

  # If 'inline' is true Resque will call #perform method inline
  # without queuing it into Redis and without any Resque callbacks.
  # The 'inline' is false Resque jobs will be put in queue regularly.
  def inline?
    @inline
  end
  alias_method :inline, :inline?

  def inline=(inline)
    @inline = inline
  end

  #
  # translations 
  #

  def add_translation(from, to)
    redis.set("from:#{from}", to)
    redis.lpush(:froms, from) 
    redis.lpush(:tos, to) 
    redis.rpush("to:#{to}", from) 
  end

  def add_translations(to, froms)
    froms.each {|from|  add_translation(from, to)}
  end

  def num_translations(to)
    Rewritten.size("to:#{to}")
  end

  def remove_translation(from, to)
    Rewritten.redis.del("from:#{from}")
    Rewritten.redis.lrem("froms", 0, from)
    Rewritten.redis.lrem("to:#{to}", 0, from)
    Rewritten.redis.lrem("tos", 0, to) if num_translations(to) == 0
 end

  def remove_all_translations(to)
    get_all_translations(to).each do |from|
      Rewritten.remove_translation(from, to)
    end
  end

  def get_all_translations(to)
    Rewritten.redis.lrange("to:#{to}", 0, -1)
  end

  def get_current_translation(path)
    translation = Rewritten.list_range("to:#{path}", -1)  
    return translation if translation
    return path
  end



  def add_hit(path, code, content_type)
    h = {:path => path, :code => code, :content_type => content_type}
    Rewritten.redis.sadd("hits", encode(h) )
  end

  def all_hits
    Rewritten.redis.smembers("hits").map{|e| decode(e)}
  end

  def include?(path)
    Rewritten.redis.get("from:#{path}")
  end

  #
  # queue manipulation
  #

  # Pushes a job onto a queue. Queue name should be a string and the
  # item should be any JSON-able Ruby object.
  #
  # Resque works generally expect the `item` to be a hash with the following
  # keys:
  #
  #   class - The String name of the job to run.
  #    args - An Array of arguments to pass the job. Usually passed
  #           via `class.to_class.perform(*args)`.
  #
  # Example
  #
  #   Resque.push('archive', :class => 'Archive', :args => [ 35, 'tar' ])
  #
  # Returns nothing
  def push(queue, item)
    watch_queue(queue)
    redis.rpush "queue:#{queue}", encode(item)
  end

  # Pops a job off a queue. Queue name should be a string.
  #
  # Returns a Ruby object.
  def pop(queue)
    decode redis.lpop("queue:#{queue}")
  end

  # Returns an integer representing the size of translations for a target. 
  # Target name should be a string.
  def size(target)
    #redis.llen("target:#{target}").to_i
    redis.llen(target).to_i
  end

  # Returns an array of items currently queued. Queue name should be
  # a string.
  #
  # start and count should be integer and can be used for pagination.
  # start is the item to begin, count is how many items to return.
  #
  # To get the 3rd page of a 30 item, paginatied list one would use:
  #   Resque.peek('my_list', 59, 30)
  def peek(queue, start = 0, count = 1)
    list_range("queue:#{queue}", start, count)
  end

  # Does the dirty work of fetching a range of items from a Redis list
  # and converting them into Ruby objects.
  def list_range(key, start = 0, count = 1)
    if count == 1
      #decode redis.lindex(key, start)
      redis.lindex(key, start)
    else
      Array(redis.lrange(key, start, start+count-1)).map do |item|
        #decode item
        item
      end
    end
  end

  # Returns an array of all known Resque queues as strings.
  def queues
    Array(redis.smembers(:queues))
  end

  # Returns an array of all known URL targets.
  def targets 
    Array(redis.smembers(:targets))
  end

  # Returns an array of all known source URLs (that are to translated)
  def froms
    Array(redis.smembers(:froms))
  end



  # Given a queue name, completely deletes the queue.
  def remove_queue(queue)
    redis.srem(:queues, queue.to_s)
    redis.del("queue:#{queue}")
  end

  # Used internally to keep track of which queues we've created.
  # Don't call this directly.
  def watch_queue(queue)
    redis.sadd(:queues, queue.to_s)
  end


  #
  # job shortcuts
  #

  # This method can be used to conveniently add a job to a queue.
  # It assumes the class you're passing it is a real Ruby class (not
  # a string or reference) which either:
  #
  #   a) has a @queue ivar set
  #   b) responds to `queue`
  #
  # If either of those conditions are met, it will use the value obtained
  # from performing one of the above operations to determine the queue.
  #
  # If no queue can be inferred this method will raise a `Resque::NoQueueError`
  #
  # This method is considered part of the `stable` API.
  def enqueue(klass, *args)
    Job.create(queue_from_class(klass), klass, *args)

    Plugin.after_enqueue_hooks(klass).each do |hook|
      klass.send(hook, *args)
    end
  end

  # This method can be used to conveniently remove a job from a queue.
  # It assumes the class you're passing it is a real Ruby class (not
  # a string or reference) which either:
  #
  #   a) has a @queue ivar set
  #   b) responds to `queue`
  #
  # If either of those conditions are met, it will use the value obtained
  # from performing one of the above operations to determine the queue.
  #
  # If no queue can be inferred this method will raise a `Resque::NoQueueError`
  #
  # If no args are given, this method will dequeue *all* jobs matching
  # the provided class. See `Resque::Job.destroy` for more
  # information.
  #
  # Returns the number of jobs destroyed.
  #
  # Example:
  #
  #   # Removes all jobs of class `UpdateNetworkGraph`
  #   Resque.dequeue(GitHub::Jobs::UpdateNetworkGraph)
  #
  #   # Removes all jobs of class `UpdateNetworkGraph` with matching args.
  #   Resque.dequeue(GitHub::Jobs::UpdateNetworkGraph, 'repo:135325')
  #
  # This method is considered part of the `stable` API.
  def dequeue(klass, *args)
    Job.destroy(queue_from_class(klass), klass, *args)
  end

  # Given a class, try to extrapolate an appropriate queue based on a
  # class instance variable or `queue` method.
  def queue_from_class(klass)
    klass.instance_variable_get(:@queue) ||
      (klass.respond_to?(:queue) and klass.queue)
  end

  # This method will return a `Resque::Job` object or a non-true value
  # depending on whether a job can be obtained. You should pass it the
  # precise name of a queue: case matters.
  #
  # This method is considered part of the `stable` API.
  def reserve(queue)
    Job.reserve(queue)
  end

  # Validates if the given klass could be a valid Resque job
  #
  # If no queue can be inferred this method will raise a `Resque::NoQueueError`
  #
  # If given klass is nil this method will raise a `Resque::NoClassError`
  def validate(klass, queue = nil)
    queue ||= queue_from_class(klass)

    if !queue
      raise NoQueueError.new("Jobs must be placed onto a queue.")
    end

    if klass.to_s.empty?
      raise NoClassError.new("Jobs must be given a class.")
    end
  end


  #
  # worker shortcuts
  #

  # A shortcut to Worker.all
  def workers
    Worker.all
  end

  # A shortcut to Worker.working
  def working
    Worker.working
  end

  # A shortcut to unregister_worker
  # useful for command line tool
  def remove_worker(worker_id)
    worker = Resque::Worker.find(worker_id)
    worker.unregister_worker
  end

  #
  # stats
  #

  # Returns a hash, similar to redis-rb's #info, of interesting stats.
  def info
    return {
      :pending   => queues.inject(0) { |m,k| m + size(k) },
      #:processed => Stat[:processed],
      #:queues    => queues.size,
      #:workers   => workers.size.to_i,
      #:working   => working.size,
      #:failed    => Stat[:failed],
      :servers   => [redis_id],
      :environment  => ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
    }
  end

  # Returns an array of all known Resque keys in Redis. Redis' KEYS operation
  # is O(N) for the keyspace, so be careful - this can be slow for big databases.
  def keys
    redis.keys("*").map do |key|
      key.sub("#{redis.namespace}:", '')
    end
  end

  def per_page
    20
  end

  
end

