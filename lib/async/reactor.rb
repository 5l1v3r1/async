# Copyright, 2017, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative 'logger'
require_relative 'task'
require_relative 'wrapper'

require 'nio'
require 'timers'
require 'forwardable'

module Async
	
  # The Async::TimeoutError class to manage
  # RuntimeErrors when they happen because of a Timeout.
  # @author Samuel Williams  
  class TimeoutError < RuntimeError
	end

  # The Async::Reactor class manages the logic for the reactor
  # pattern implemented in this gem.
  # @params args [Array] catch all for arguments
  #
	class Reactor < Node
		extend Forwardable
		
    # Start running the Reactor.
    # @todo (picat) Clarify this.
    # @params args [Array]
    # @return [Reactor]
		def self.run(*args, &block)
      if current = Task.current?
				reactor = current.reactor
				
				reactor.async(*args, &block)
			else
				reactor = self.new
				
				begin
					reactor.run(*args, &block)
				ensure
					reactor.close
				end
				
				return reactor
			end
		end
	
    # Create a Reactor.
    # @return [void]
		def initialize(wrappers: IO)
			super(nil)
			
			@wrappers = wrappers
			
			@selector = NIO::Selector.new
			@timers = Timers::Group.new
			
			@stopped = true
		end
	
    # @attr wrappers [Object] 
		attr :wrappers
    # @attr stopped [Boolean] 
		attr :stopped
		
		def_delegators :@timers, :every, :after
	
    # Wrap a given IO object and associted Task.  
		# @param io [IO]
		# @param task [Task]
    # @return [Wrapper]
    def wrap(io, task)
			@wrappers[io].new(io, task)
		end
	
		def with(io, &block)
			async do |task|
				task.with(io, &block)
			end
		end

    # @return [Task]  
		def async(*ios, &block)
			task = Task.new(ios, self, &block)
			
			# I want to take a moment to explain the logic of this.
			# When calling an async block, we deterministically execute it until the
			# first blocking operation. We don't *have* to do this - we could schedule
			# it for later execution, but it's useful to:
			# - Fail at the point of call where possible.
			# - Execute determinstically where possible.
			# - Avoid overhead if no blocking operation is performed.
			task.run
			
			# Async.logger.debug "Initial execution of task #{fiber} complete (#{result} -> #{fiber.alive?})..."
			return task
		end
		
		def register(*args)
			@selector.register(*args)
		end
	
    # Stop the Reactor.
    # @return [void]  
		def stop
			@stopped = true
		end
	
		# @todo (picat) Please clarify this.
    def run(*args, &block)
			raise RuntimeError, 'Reactor has been closed' if @selector.nil?
			
			@stopped = false
			
			# Allow the user to kick of the initial async tasks.
			async(*args, &block) if block_given?
			
			@timers.wait do |interval|
				# - nil: no timers
				# - -ve: timers expired already
				# -   0: timers ready to fire
				# - +ve: timers waiting to fire
				interval = 0 if interval && interval < 0
				
				Async.logger.debug{"[#{self} Pre] Updating #{@children.count} children..."}
				Async.logger.debug{@children.collect{|child| [child.to_s, child.alive?]}.inspect}
				# As timeouts may have been updated, and caused fibers to complete, we should check this.
				
				# If there is nothing to do, then finish:
				Async.logger.debug{"[#{self}] @children.empty? = #{@children.empty?} && interval #{interval.inspect}"}
				return if @children.empty? && interval.nil?
				
				Async.logger.debug{"Selecting with #{@children.count} fibers interval = #{interval}..."}
				if monitors = @selector.select(interval)
					monitors.each do |monitor|
						if fiber = monitor.value
							# Async.logger.debug "Resuming task #{task} due to IO..."
							fiber.resume
						end
					end
				end
			end until @stopped
			
			return self
		ensure
			Async.logger.debug{"[#{self} Ensure] Exiting run-loop (stopped: #{@stopped} exception: #{$!})..."}
			Async.logger.debug{@children.collect{|child| [child.to_s, child.alive?]}.inspect}
			@stopped = true
		end
	
    # Close each of the children and selector.  
    # @return [void]
		def close
			@children.each(&:stop)
			
			@selector.close
			@selector = nil
		end
		
    # Check if the selector has been closed,
    # meaning the +close+ method was probably worked.
    # @return [Boolean]
		def closed?
			@selector.nil?
		end
	
    # Put the Reactor to sleep for a given ammount of time.
    # @params duration [Integer]  
		def sleep(duration)
			task = Fiber.current
			
			timer = self.after(duration) do
				if task.alive?
					task.resume
				end
			end
			
			Task.yield
		ensure
			timer.cancel if timer
		end
		
    # @params duration [Integer]  
		def timeout(duration)
			backtrace = caller
			task = Fiber.current
			
			timer = self.after(duration) do
				if task.alive?
					error = TimeoutError.new("execution expired")
					error.set_backtrace backtrace
					task.resume error
				end
			end
			
			yield
		ensure
			timer.cancel if timer
		end
	end
end
