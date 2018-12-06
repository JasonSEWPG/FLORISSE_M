classdef estimator < handle
    %VISUALIZER Summary of this class goes here
    %   Detailed explanation goes here
    
    properties
        estimParamsAll
        florisObjSet
        measurementSet
    end
    
    methods
        function obj = estimator(florisObjSet,measurementSet)
            % Store the relevant properties from the FLORIS object
            obj.florisObjSet   = florisObjSet;
            obj.measurementSet = measurementSet;
            
            if length(measurementSet) ~= length(florisObjSet)
                error('The measurementSet dimensions should match that of the florisObjSet.');
            end
            
            % Determine the collective set of estimation parameters
            estimParamsAll = {};
            checkAlphabeticalOrder = @(x) any(strcmp(unique(x),x)==0);
            for i = 1:length(measurementSet)
                if checkAlphabeticalOrder(measurementSet{i}.estimParams)
                    error('Please specify measurementSet.estimParams in alphabetical order.');
                end
                estimParamsAll = {estimParamsAll{:} measurementSet{i}.estimParams{:}};
            end
            obj.estimParamsAll = unique(estimParamsAll);
            disp(['Collective param. estimation set: [' strjoin(obj.estimParamsAll,', ') ']'])
        end
        
        function [xopt,Jopt] = gaEstimation(obj,lb,ub)
            ga_A   = []; % Condition A * x <= b
            ga_b   = []; % Condition A * x <= b
            ga_Aeq = []; % Condition Aeq * x == beq
            ga_beq = []; % Condition Aeq * x == beq
            
            costFun = @(x) obj.costWeightedRMSE(x);
            
            % Optimize using Parallel Computing
            nVars = length(obj.estimParamsAll);
            %             options = gaoptimset('Display','iter', 'TolFun', 1e-3,'UseParallel', true); No plotting
            options = gaoptimset('Display','iter', 'TolFun', 1e-3,'UseParallel', true,'PlotFcns',{@plotfun1}); % with plot
            [xopt,Jopt,exitFlag,output,population,scores] = ga(costFun, nVars, ga_A, ga_b, ga_Aeq, ga_beq, lb, ub, [], options);
            
            function state = plotfun1(options,state,flag)
                subplot(2,1,1);
                [~,idx]=min(state.Score);
                optSettings=state.Population(idx,:);
                bar(optSettings);
                text(1:length(optSettings),optSettings,num2str(optSettings'),'vert','bottom','horiz','center');
                ylabel('Value');
                xlabel('Estimation variables');
                grid on; box on;
                
                subplot(2,1,2);
                plot(1:length(state.Best),state.Best,'kd','MarkerFaceColor',[1 0 1]);
                ylabel('Cost');
                xlim([0 20]);
                xlabel('Generation');
                grid on; box on;
                
                %                 set(gcf,'color','w');
                %                 export_fig(['estimationOutputs/kOut/' num2str(state.Generation) '.png'],'-m2');
            end
        end
        
        function [J] = costWeightedRMSE(obj,x);
            florisObjSet   = obj.florisObjSet;
            measurementSet = obj.measurementSet;
            estimParamsAll = obj.estimParamsAll;
            
            if length(x) ~= length(estimParamsAll)
                error('The variable [x] has to be of equal length as [estimationParams].');
            end
            
            % Reset cost function
            Jset = zeros(1,length(florisObjSet));
            
            % Update the parameters with [x] of each floris object, if required
            for i = 1:length(florisObjSet)
                florisObjTmp = copy(florisObjSet{i});
                for ji = 1:length(estimParamsAll)
                    % Update parameter iff is tuned for measurement set [i]
                    if ismember(estimParamsAll{ji},measurementSet{i}.estimParams)
                        if ismember(estimParamsAll{ji},{'Vref','TI0','windDirection'})
                            florisObjTmp.layout.ambientInflow.(estimParamsAll{ji}) = x(ji);
                        else
                            florisObjTmp.model.modelData.(estimParamsAll{ji}) = x(ji);
                        end
                    end
                end
                % if WD changed, we need to redefine which yaw angles
                % we want maintain (WF or IF). Here, we enforce the
                % consistent yaw angles in the INERTIAL frame.
                florisObjTmp.controlSet.yawAngleIFArray = florisObjTmp.controlSet.yawAngleIFArray;
                
                
                % Execute FLORIS with [x]
                florisObjTmp.run();
                
                % Calculate weighted power RMSE, if applicable
                if any(ismember(fields(measurementSet{i}),'P'))
                    powerError = [florisObjTmp.turbineResults.power] - measurementSet{i}.P.values;
                    Jset(i)    = Jset(i) + sqrt(mean((powerError ./ measurementSet{i}.P.stdev).^2));
                end
                
                % Calculate weighted flow RMSE, if applicable
                if any(ismember(fields(measurementSet{i}),'U'))
                    fixYaw  = false;
                    uProbes = compute_probes(florisObjTmp,measurementSet{i}.U.x,measurementSet{i}.U.y,measurementSet{i}.U.z,fixYaw);
                    avgWSerror = uProbes - measurementSet{i}.U.values;
                    Jset(i)   = Jset(i) + sqrt(mean((avgWSerror ./ measurementSet{i}.U.stdev).^2));
                end
                
                % Calculate sector-averaged flow speed RMSE, if applicable
                if any(ismember(fields(measurementSet{i}),'virtTurb'))
                    fixYaw  = false;
                    
                    % Create flow field object
                    flowFieldRes = measurementSet{i}.virtTurb.zPts(2)-measurementSet{i}.virtTurb.zPts(1);
                    flowField = struct();
                    [flowField.X, flowField.Y, flowField.Z] = meshgrid(...
                        measurementSet{i}.virtTurb.x(:,1)', ...
                        min(measurementSet{i}.virtTurb.y(:))-.75*measurementSet{i}.virtTurb.Drotor : flowFieldRes : max(measurementSet{i}.virtTurb.y(:))+.75*measurementSet{i}.virtTurb.Drotor, ...
                        0 : flowFieldRes : max(measurementSet{i}.virtTurb.z(:))+.75*measurementSet{i}.virtTurb.Drotor);
                                        
                    % Set-up the FLORIS object, exporting the variables of interest
                    layout               = florisObjTmp.layout;
                    turbineResults       = florisObjTmp.turbineResults;
                    yawAngles            = florisObjTmp.controlSet.yawAngleWFArray;
                    avgWs                = [florisObjTmp.turbineConditions.avgWS];
                    wakeCombinationModel = florisObjTmp.model.wakeCombinationModel;
                    
                    % Calculate flow field
                    flowField.U = layout.ambientInflow.Vfun(flowField.Z);
                    flowField = compute_flow_field(flowField, layout, turbineResults, ...
                        yawAngles, avgWs, fixYaw, wakeCombinationModel);
                    
                    % Calculate UAvg for each virtual location  
                    for ix = 1:size(flowField.X,2) % For each slice
                        Y = squeeze(flowField.Y(:,ix,:));
                        Z = squeeze(flowField.Z(:,ix,:));
                        F = griddedInterpolant(Y,Z,squeeze(flowField.U(:,ix,:)));
                        
                        for iy = 1:size(measurementSet{i}.virtTurb.y,2)
                            yVirtTurb = measurementSet{i}.virtTurb.y(ix,iy);
                            yPts_tmp = yVirtTurb + measurementSet{i}.virtTurb.yPts;
                            zPts_tmp = measurementSet{i}.virtTurb.z(ix,1) + measurementSet{i}.virtTurb.zPts;
                            UAvg_floris(ix,iy) = mean(F(yPts_tmp,zPts_tmp));
                        end
                    end
                    
                    % Add  weighted cost per slice to overall cost function
                    avgWSerror = UAvg_floris - measurementSet{i}.virtTurb.UAvg;
                    for ix = 1:size(avgWSerror,1)
                        Jset(i)   = Jset(i) + sqrt(mean((avgWSerror(ix,:) / measurementSet{i}.virtTurb.stdev(ix)).^2));
                    end
                end
            end
            
            % Final cost
            J = sum(Jset);
        end
        
    end
    
    methods (Hidden)
        %
    end
end

