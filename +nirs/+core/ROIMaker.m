classdef ROIMaker
    %% ROIMaker - Averages data into ROIs
    % 
    % Properties: 
    %     description  - description of ROI set (e.g. filename)
    %     probeChannel - (readonly) the original channel-based probe (see set_probe)
    %     probeROI     - (dependent) the generated ROI-based probe
    %     sources      - (readonly) cell array of sources (one set per ROI)
    %     detectors    - (readonly) cell array of detectors (one set per ROI)
    %     names        - (readonly) cell array of names of each ROI
    %     
    %  Methods:
    %     set_probe   - Sets the original channel-based probe (input: probe or probe1020)
    %                 -   Ex. ROImaker = ROImaker.set_probe( hb(1).probe )
    %
    %     add_ROI     - Adds a region of interest (inputs: sources, detectors, name)
    %                     Ex. ROImaker = ROImaker.add_ROI( [1 1 1], [1 2 3], 'left dlPFC')
    %
    %     apply       - Applies ROIs to data (Data, ChannelStats, sFCStats)
    %                     Ex. SubjStats = ROImaker.apply( SubjStats );

    properties
        description     % description of probe/ROIs
    end

    properties (SetAccess = private)
        probeChannel    % Original channel-based nirs.core.Probe or nirs.core.Probe1020
        sources         % [1 x #ROI] cell array of sources
        detectors       % [1 x #ROI] cell array of detectors
        names           % [1 x #ROI] cell array of ROI names
    end
    
    properties ( Dependent = true )
        probeROI        % Probe object describing measurement geometry
    end
    
    methods
        
        % Sets the original channel-space probe
        function obj = set_probe( obj , probe )
            if ~isa(probe,'nirs.core.Probe') || ~isa(probe,'nirs.core.Probe1020')
                error('Probe is not correct type');
            end
            obj.probeChannel = probe;
        end
        
        % Adds an ROI to the list
        function obj = add_ROI( obj , sources , detectors , names )
            if isnumeric(sources)
                sources = {sources};
            end
            if isnumeric(detectors)
                detectors = {detectors};
            end
            if ~exist('names','var')
                names = cell(1,length(sources));
                for i=1:length(sources)
                    names{i} = sprintf('ROI %i',i);
                end
            end
            if ischar(names)
                names = {names};
            end
            if isempty(obj.probeChannel)
                error('Must set probeChannel before adding ROIs');
            end
            channelsources = obj.probeChannel.link.source;
            channeldetectors = obj.probeChannel.link.detector;
            for k = 1:max(length(sources),length(detectors))
                if ~isempty(setdiff(sources{k},channelsources)) || ~isempty(setdiff(detectors{k},channeldetectors))
                    error('Attempted to add sources or detectors that don''t exist in channel probe');
                end
                if any(strcmp(obj.names,names{k}))
                    error('Attempted to add ROI with same name: %s',names{k});
                end
            end
            
            obj.sources = [obj.sources sources(:)'];
            obj.detectors = [obj.detectors detectors(:)'];
            obj.names = [obj.names names(:)'];
        end
        
        % Resets the probe and ROIs
        function obj = reset( obj )
            obj.probeChannel = [];
            obj.sources = {};
            obj.detectors = {};
            obj.names = {};
        end
    
        % Generates a new probe for the ROIs (source & detector fields in
        % link are now arrays and link has 'ROI' column with the region name)
        function probeROI = get.probeROI( obj )
            if isempty(obj.probeChannel)
                probeROI = [];
                return
            end
            source = obj.sources;
            detector = obj.detectors;
            name = obj.names;
            probe = obj.probeChannel;
            link = probe.link;
            types = unique(link.type,'stable');
            
            link = table({},{},{},{},'VariableNames',{'source','detector','type','ROI'});
            for i = 1:length(source)
                for j = 1:length(types)
                    link(end+1,:) = table(source(i),detector(i),types(j),name(i));
                end
            end

            if any(strcmp(probe.link.Properties.VariableNames,'hyperscan'))
                inds_A = strfind( probe.link.hyperscan' , 'A' );
                inds_B = strfind( probe.link.hyperscan' , 'B' );
                hyper_source_offset = min(probe.link.source(inds_B)) - min(probe.link.source(inds_A));
                hyper_detector_offset = min(probe.link.detector(inds_B)) - min(probe.link.detector(inds_A));
                linkA = link; linkA.hyperscan = repmat('A',[height(link) 1]);
                linkB = link; linkB.hyperscan = repmat('B',[height(link) 1]);
                for i = 1:height(linkB)
                    linkB.source{i} = linkB.source{i} + hyper_source_offset;
                    linkB.detector{i} = linkB.detector{i} + hyper_detector_offset;
                end
                link = [linkA; linkB];
            end
            
            probe.link = link;
            probeROI = probe;
        end
        
        % Returns a [#channel x 1] logical of channels within specified ROI
        function inds = getChannelInds(obj,s,d,t)
            chanlink = obj.probeChannel.link;
            inds = false(height(chanlink),1);
            for i = 1:length(s)
                inds = inds | (chanlink.source==s(i) & chanlink.detector==d(i) & strcmpi(chanlink.type,t));
            end
        end
        
        % Returns a [#channel x #ROI] binary projection matrix
        function mapping = getMapping( obj )
            chanlink = obj.probeChannel.link;
            roilink = obj.probeROI.link;
            num_chan = height(chanlink);
            num_ROI = height(roilink);
            
            mapping = zeros(num_chan,num_ROI);
            for i = 1:num_ROI
                inds = obj.getChannelInds(roilink.source{i},roilink.detector{i},roilink.type{i});
                mapping(inds,i) = 1/sum(inds);
            end
        end
        
        % Apply ROI averaging to data and update probe
        function dataROI = apply( obj , dataChannel )
            oldprobe = obj.probeChannel;
            probe = obj.probeROI;
            if isempty(probe)
                error('Must setup channel probe and ROIs first');
            end
            if ~any(strcmp(probe.link.Properties.VariableNames,'ROI'))
                error('No ROIs detected in probeROI');
            end
            
            for i = 1:length(dataChannel)
                if ~isequal(dataChannel(i).probe,oldprobe)
                    error('Data probe %i does not match original channel probe used to create ROI probe',i);
                end
            end
            
            dataROI = dataChannel;
            switch class(dataChannel)
                case {'nirs.core.Data'}
                    projmat = obj.getMapping;
                    for i = 1:length(dataChannel)
                        dataROI(i).probe = probe;
                        dataROI(i).data = zscore(dataChannel(i).data) * projmat;
                    end
                    
                case {'nirs.core.ChannelStats'}
                    projmat = obj.getMapping;
                    for i = 1:length(dataChannel)
                        dataROI(i).probe = probe;
                        conds = unique(dataChannel(i).variables.cond,'stable');
                        numcond = length(conds);
                        condvec = repmat(conds(:)',[height(probe.link) 1]);
                        condprojmat = kron(eye(numcond),projmat);
                        dataROI(i).beta = condprojmat' * dataChannel(i).beta;
                        dataROI(i).covb = condprojmat' * dataChannel(i).covb * condprojmat;
                        dataROI(i).variables = repmat(probe.link,numcond,1);
                        dataROI(i).variables.cond = condvec(:);
                    end
                    
                case {'nirs.core.sFCStats'}
                    projmat = obj.getMapping;
                    for i = 1:length(dataChannel)
                        
                        dataROI(i).probe = probe;
                        numconds = length(dataChannel(i).conditions);
                        ROI_size = [size(projmat,2) size(projmat,2) numconds];
                        
                        % Transform R values
                        R_nan_Channel = isnan(dataChannel(i).R);
                        R_nan_ROI = zeros(ROI_size);
                        dataChannel(i).R(R_nan_Channel) = 0;
                        dataROI(i).R = zeros(ROI_size);
                        for j = 1:length(dataChannel(i).conditions)
                            dataROI(i).R(:,:,j) = projmat' * dataChannel(i).R(:,:,j) * projmat;
                            R_nan_ROI(:,:,j) = projmat' * R_nan_Channel(:,:,j) * projmat;
                        end
                        dataROI(i).R(R_nan_ROI~=0) = nan;
                        
                        % Transform ZstdErr if it exists
                        if ~isempty(dataChannel(i).ZstdErr)
                            Z_nan_Channel = isnan(dataChannel(i).ZstdErr);
                            Z_nan_ROI = zeros(ROI_size);
                            dataChannel(i).ZstdErr(Z_nan_Channel) = 0;
                            dataROI(i).ZstdErr = zeros(ROI_size);
                            for j = 1:length(dataChannel(i).conditions)
                                dataROI(i).ZstdErr(:,:,j) = projmat' * dataChannel(i).ZstdErr(:,:,j) * projmat;
                                Z_nan_ROI(:,:,j) = projmat' * Z_nan_Channel(:,:,j) * projmat;
                            end
                            dataROI(i).ZstdErr(Z_nan_ROI~=0) = nan;
                        end
                    end
                    
                otherwise
                    error('Type %s not implemented.',class(dataChannel));
            end
        end
    end
    
end