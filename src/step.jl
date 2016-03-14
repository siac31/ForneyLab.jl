export  attachReadBuffer,
        attachWriteBuffer,
        detachReadBuffer,
        detachWriteBuffer,
        detachBuffers,
        emptyWriteBuffers,
        execute,
        step,
        run

import Base.run
import Base.step

function ensureValue!(node::TerminalNode, value_type::Type)
    # Ensure that node contains a value of type value_type
    if !isdefined(node, :value) || (typeof(node.value) != value_type)
        if (value_type <: DeltaDistribution{Float64}) || (value_type <: Float64)
            node.value = DeltaDistribution()
        elseif (value_type <: DeltaDistribution{Bool}) || (value_type <: Bool)
            node.value = DeltaDistribution(false)
        elseif (value_type <: MvDeltaDistribution) || (value_type <: Vector{Float64})
            dims = value_type.parameters[end]
            node.value = MvDeltaDistribution(zeros(dims))
        else
            node.value = vague(value_type)
        end
    end

    return node.value
end

function attachReadBuffer(node::TerminalNode, buffer::Vector, graph::FactorGraph=currentGraph())
    hasNode(graph, node) || error("The specified node is not part of the current or specified graph")
    ensureValue!(node, typeof(node.value)) # Ensures that a value of correct type is set for message type inference
    graph.read_buffers[node] = buffer
end

function attachReadBuffer{T<:Node}(nodes::Vector{T}, buffer::Vector, graph::FactorGraph=currentGraph())
    # Mini-batch assignment for read buffers.
    # buffer is divided over nodes equally.
    n_nodes = length(nodes)
    n_samples_per_node = round(Int, floor(length(buffer)/length(nodes)))
    n_samples_per_node*n_nodes == length(buffer) || error("Buffer length must a multiple of the mini-batch node array length")
    buffmat = reshape(buffer, n_nodes, n_samples_per_node) # samples for one node are present in the rows of buffmat
    for k in 1:n_nodes
        hasNode(graph, nodes[k]) || error("One of the specified nodes is not part of the current or specified graph")
        (typeof(nodes[k]) <: TerminalNode) || error("$(nodes[k]) is not a TerminalNode")
        ensureValue!(nodes[k], typeof(buffmat[k,1])) # Ensures that a value of correct type is set for message type inference
        graph.read_buffers[nodes[k]] = vec(buffmat[k,:])
    end

    return graph.read_buffers[nodes[end]] # Return last node's buffer
end

function detachReadBuffer(nd::TerminalNode, graph::FactorGraph=currentGraph())
    hasNode(graph, nd) || error("The specified node is not part of the current or specified graph")
    haskey(graph.read_buffers, nd) || error("There is no read buffer attached to the specified node")

    delete!(graph.read_buffers, nd)
    return graph
end

function attachWriteBuffer(interface::Interface, buffer::Vector=Array(ProbabilityDistribution,0), graph::FactorGraph=currentGraph())
    hasNode(graph, interface.node) || error("The specified interface is not part of the current or specified graph")
    if isdefined(graph, :block_size)
        (length(buffer) == graph.block_size) || error("The length of write buffer should be equal to the graph block size.")  
    end
    graph.write_buffers[interface] = buffer # Write buffer for message
end

function detachWriteBuffer(interface::Interface, graph::FactorGraph=currentGraph())
    hasNode(graph, interface.node) || error("The specified interface is not part of the current or specified graph")
    haskey(graph.write_buffers, interface) || error("There is no write buffer attached to the specified interface")

    delete!(graph.write_buffers, interface)
    return graph
end

function attachWriteBuffer(edge::Edge, buffer::Vector=Array(ProbabilityDistribution,0), graph::FactorGraph=currentGraph())
    hasEdge(graph, edge) || error("The specified edge is not part of the current or specified graph")
    if isdefined(graph, :block_size)
        (length(buffer) == graph.block_size) || error("The length of write buffer should be equal to the graph block size.")  
    end
    graph.write_buffers[edge] = buffer # Write buffer for marginal
end

function detachWriteBuffer(edge::Edge, graph::FactorGraph=currentGraph())
    hasEdge(graph, edge) || error("The specified edge is not part of the current or specified graph")
    haskey(graph.write_buffers, edge) || error("There is no write buffer attached to the specified edge")

    delete!(graph.write_buffers, edge)
    return graph
end

function detachBuffers(graph::FactorGraph=currentGraph())
    graph.read_buffers = Dict{TerminalNode, Vector}()
    graph.write_buffers = Dict{Union{Edge,Interface}, Vector}()
end

function emptyWriteBuffers(graph::FactorGraph=currentGraph())
    for (k, v) in graph.write_buffers
        empty!(v) # Clear the vector but keep the pointer
    end
end

function execute(algorithm::InferenceAlgorithm)
    # Call algorithm's execute function with itself as argument
    # prepare!(algorithm) should always be called before the first call to execute(algorithm)

    return algorithm.execute(algorithm)
end

function step(wrap::Wrap, direction::Type{Val{:forward}}, graph::FactorGraph=currentGraph())
    if isdefined(graph, :block_size)
        wrap.tail_buffer[graph.current_section] = deepcopy(wrap.tail.interfaces[1].partner.message.payload)
        wrap.head.value = wrap.tail_buffer[graph.current_section]
        if isdefined(wrap.head_buffer, graph.current_section) 
            wrap.tail.value = wrap.head_buffer[graph.current_section]
        end
    else
        wrap.head.value = deepcopy(wrap.tail.interfaces[1].partner.message.payload)
    end
end

function step(wrap::Wrap, direction::Type{Val{:backward}}, graph::FactorGraph=currentGraph())
    wrap.head_buffer[graph.current_section] = deepcopy(wrap.head.interfaces[1].partner.message.payload)
    wrap.tail.value = wrap.head_buffer[graph.current_section]
    if isdefined(wrap.tail_buffer, graph.current_section)
        wrap.head.value = wrap.tail_buffer[graph.current_section]
    end
end

function step(algorithm::InferenceAlgorithm, direction::Symbol, graph::FactorGraph=currentGraph())
    step(algorithm, Val{direction}, graph)
end

step(algorithm::InferenceAlgorithm) = step(algorithm, :forward)

function write_message_from_component_to_buffer!(component::Edge, write_buffer::Vector{ProbabilityDistribution}, graph::FactorGraph=currentGraph())
    if isdefined(graph, :block_size)
        write_buffer[graph.current_section] = deepcopy(calculateMarginal!(component))
    else
        push!(write_buffer, deepcopy(calculateMarginal!(component)))
    end
end

function write_message_from_component_to_buffer!(component::Interface, write_buffer::Vector{ProbabilityDistribution}, graph::FactorGraph=currentGraph())
    if isdefined(graph, :block_size)
        write_buffer[graph.current_section] = deepcopy(component.message.payload)
    else
        push!(write_buffer, deepcopy(component.message.payload))
    end
end

function step(algorithm::InferenceAlgorithm, direction::Type{Val{:forward}}, graph::FactorGraph=currentGraph())
    # Execute algorithm for 1 timestep.
    # prepare!(algorithm) should always be called before the first call to step(algorithm)
    
    if isdefined(graph, :block_size) && graph.current_section > graph.block_size
        error("Further forward steps are impossible since you stepped outside of the block.")
    end
    
    # Read buffers

    for (terminal_node, read_buffer) in graph.read_buffers
        terminal_node.value = read_buffer[graph.current_section] # pick the proper element from the read_buffer
    end

    # Execute schedule
    result = execute(algorithm)

    # Write buffers
    for (component, write_buffer) in graph.write_buffers
        write_message_from_component_to_buffer!(component, write_buffer)
    end

    # Wraps
    for wrap in wraps(graph)
        step(wrap, direction)
    end
    
    graph.current_section += 1
    
    return result
end

function step(algorithm::InferenceAlgorithm, direction::Type{Val{:backward}}, graph::FactorGraph=currentGraph())
    # Execute algorithm for 1 timestep.
    # prepare!(algorithm) should always be called before the first call to step(algorithm)
    
    isdefined(graph, :block_size) || error("Backward passes are not allowed if the block size is not defined.")
    graph.current_section > 0 || error("You did too many backward passes and stepped out of the block.") 

    graph.current_section -= 1
    
    # Read buffers
    for (terminal_node, read_buffer) in graph.read_buffers
        terminal_node.value = read_buffer[graph.current_section] # pick the proper element from the read_buffer
    end

    # Execute schedule
    result = execute(algorithm)

    # Write buffers
    for (component, write_buffer) in graph.write_buffers
        write_message_from_component_to_buffer!(component, write_buffer)
    end

    # Wraps
    for wrap in wraps(graph)
        step(wrap, direction)
    end

    return result
end

function read_buffers_contain_enough_elements(graph::FactorGraph=currentGraph())
    if length(graph.read_buffers) > 0
        for (node, read_buffer) in graph.read_buffers
            if length(read_buffer) < graph.current_section
                return false
            end
        end
        return true
    else
        return false
    end
end


function run(algorithm::InferenceAlgorithm, graph::FactorGraph=currentGraph(); n_steps::Int64=0, direction::Symbol=:forward)
    # Call step(algorithm) repeatedly
    prepare!(algorithm)

    if n_steps > 0 # When a valid number of steps is specified, execute the algorithm n_steps times in the direction
            for i = 1:n_steps
                step(algorithm, direction, graph)
            end 
    elseif length(graph.read_buffers) > 0 # If no valid n_steps is specified, run until at least one of the read buffers is exhausted
        if !isdefined(graph, :block_size)
            direction == :forward || error("Backward passes are not allowed if the block size is not defined.")
            while read_buffers_contain_enough_elements()
                step(algorithm, direction, graph)
            end
        else
            bound = direction==:backward ? 1 : 0
            while (bound < graph.current_section <= graph.block_size + bound)  #run only until the end of graph
                step(algorithm, direction, graph)
                if !read_buffers_contain_enough_elements(graph)
                    break
                end
            end
        end
    else # No read buffers or valid n_steps, just call step once
        step(algorithm, direction, graph)
    end        
end
